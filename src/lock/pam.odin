// Password check for the lock screen: PAM (Linux-PAM), run in a child
// process of the locker so the lock screen keeps drawing while modules take
// their time (pam_unix's failure delay, pam_faillock, fingerprint readers).
//
// Service: /etc/pam.d/milk when it exists (install.sh installs it), else the
// first existing one of PAM_FALLBACK_SERVICES:
//   system-auth  Arch, Fedora, Void (and other Red Hat style stacks)
//   common-auth  Debian, Ubuntu, openSUSE (their shared auth stack; only
//                "auth" lines, which is all a screen locker uses)
//   login        everywhere else
// Every one of them runs the system's whole auth stack, pam_faillock
// included: like i3lock and swaylock, a few wrong passwords may lock the
// account for a while where the distribution configures that.
//
// Test builds (-define:MILK_LOCK_TEST_PASSWORD=...) never call PAM: the
// password is compared with that constant, after a short delay, and libpam
// is not even linked.
package lock

import "core:c"
import "core:c/libc"
import "core:mem"
import "core:os"

TEST_PASSWORD :: #config(MILK_LOCK_TEST_PASSWORD, "")
TEST_BUILD :: TEST_PASSWORD != ""

PAM_SERVICE :: "milk"
PAM_FALLBACK_SERVICES :: []string{"system-auth", "common-auth", "login"}
PAM_DIRS :: []string{"/etc/pam.d", "/usr/lib/pam.d", "/usr/etc/pam.d", "/lib/pam.d"}

// The PAM service the lock screen authenticates with (see above).
pam_service :: proc() -> string {
	for name in ([]string{PAM_SERVICE}) {
		if pam_service_exists(name) { return name }
	}
	for name in PAM_FALLBACK_SERVICES {
		if pam_service_exists(name) { return name }
	}
	return "login"
}

@(private)
pam_service_exists :: proc(name: string) -> bool {
	for dir in PAM_DIRS {
		if os.is_file(join_path(dir, name)) { return true }
	}
	return false
}

// Check `password` for `user` (blocking; call it in the auth child).
authenticate :: proc(user: string, password: []u8, service: string) -> bool {
	when TEST_BUILD {
		// Never PAM: tests must not count failures against the real account.
		sleep_seconds(0.35)
		return string(password) == TEST_PASSWORD
	} else {
		return pam_authenticate_user(user, password, service)
	}
}

// PAM's types and the conversation (plain C ABI, no library needed).
@(private) PAM_SUCCESS          :: c.int(0)
@(private) PAM_PROMPT_ECHO_OFF  :: c.int(1)
@(private) PAM_PROMPT_ECHO_ON   :: c.int(2)
@(private) PAM_BUF_ERR          :: c.int(5)
@(private) PAM_CONV_ERR         :: c.int(19)
@(private) PAM_REFRESH_CRED     :: c.int(0x0010)

@(private)
pam_message :: struct {
	msg_style: c.int,
	msg:       cstring,
}

@(private)
pam_response :: struct {
	resp:         cstring,
	resp_retcode: c.int,
}

@(private)
pam_conv :: struct {
	conv:        proc "c" (num_msg: c.int, msg: [^]^pam_message, resp: ^[^]pam_response, appdata: rawptr) -> c.int,
	appdata_ptr: rawptr,
}

@(private)
Conv_Data :: struct {
	user:     cstring,
	password: cstring,
}

// The conversation: the password for hidden prompts, the user name for
// visible ones (some modules ask for it), nothing for messages. PAM frees
// the answers with free(), so they come from libc.
@(private)
conversation :: proc "c" (num_msg: c.int, msg: [^]^pam_message, resp: ^[^]pam_response, appdata: rawptr) -> c.int {
	if num_msg <= 0 || num_msg > 32 { return PAM_CONV_ERR }
	data := (^Conv_Data)(appdata)
	answers := ([^]pam_response)(libc.calloc(uint(num_msg), size_of(pam_response)))
	if answers == nil { return PAM_BUF_ERR }
	for i in 0 ..< int(num_msg) {
		switch msg[i].msg_style {
		case PAM_PROMPT_ECHO_OFF:
			answers[i].resp = cstring(libc_strdup(data.password))
		case PAM_PROMPT_ECHO_ON:
			answers[i].resp = cstring(libc_strdup(data.user))
		}
	}
	resp^ = answers
	return PAM_SUCCESS
}

foreign import libc_pam "system:c"
@(default_calling_convention="c")
foreign libc_pam {
	@(link_name="strdup") libc_strdup :: proc(s: cstring) -> [^]u8 ---
}

when !TEST_BUILD {
	// libpam.so.0 by its soname: only the runtime library is needed to build
	// (no -dev/-devel package for the libpam.so symlink).
	foreign import pam "system:libpam.so.0"

	@(default_calling_convention="c")
	foreign pam {
		pam_start        :: proc(service, user: cstring, conv: ^pam_conv, pamh: ^rawptr) -> c.int ---
		pam_end          :: proc(pamh: rawptr, status: c.int) -> c.int ---
		pam_authenticate :: proc(pamh: rawptr, flags: c.int) -> c.int ---
		pam_setcred      :: proc(pamh: rawptr, flags: c.int) -> c.int ---
	}

	@(private)
	pam_authenticate_user :: proc(user: string, password: []u8, service: string) -> bool {
		// NUL-terminated copies, wiped before returning.
		pw := make([]u8, len(password) + 1)
		defer {
			secure_zero(pw)
			delete(pw)
		}
		copy(pw, password)
		cuser := make([]u8, len(user) + 1)
		defer delete(cuser)
		copy(cuser, user)
		cservice := make([]u8, len(service) + 1)
		defer delete(cservice)
		copy(cservice, service)

		data := Conv_Data{user = cstring(raw_data(cuser)), password = cstring(raw_data(pw))}
		conv := pam_conv{conv = conversation, appdata_ptr = &data}
		handle: rawptr
		status := pam_start(cstring(raw_data(cservice)), cstring(raw_data(cuser)), &conv, &handle)
		if status != PAM_SUCCESS { return false }
		status = pam_authenticate(handle, 0)
		if status == PAM_SUCCESS {
			// Renew Kerberos tickets and the like; a failure here does not
			// keep the screen locked.
			pam_setcred(handle, PAM_REFRESH_CRED)
		}
		pam_end(handle, status)
		return status == PAM_SUCCESS
	}
}


// Overwrite a secret in a way the optimiser keeps.
secure_zero :: proc(buf: []u8) {
	if len(buf) > 0 { mem.zero_explicit(raw_data(buf), len(buf)) }
}

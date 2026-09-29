// lactase, milk's compositor, follows compositor.enabled: milk starts it
// with the session (nothing happens when it already runs) and stops it when
// the option is turned off. lactase keeps its own settings in lactase.json.
package milk

import "core:log"
import "core:sys/posix"
import desktop "../desktop"

// Start or stop lactase to match the configuration.
compositor_sync :: proc(r: ^Runner) {
	want := r.cfg.compositor.enabled
	if want == r.compositor_on { return }
	r.compositor_on = want
	if _, found := desktop.lactase_path(); !found {
		if want { log.debug("lactase is not installed; running without a compositor") }
		return
	}
	pid, ok := desktop.lactase_run(want ? "start" : "stop")
	if !ok {
		log.warnf("Could not run lactase %s", want ? "start" : "stop")
		return
	}
	append(&r.lactase_children, posix.pid_t(pid))
	log.infof("lactase %s requested", want ? "start" : "stop")
}

// The launcher returns once lactase is in the background: reap it (never blocks).
compositor_reap :: proc(r: ^Runner) {
	for i := len(r.lactase_children) - 1; i >= 0; i -= 1 {
		status: i32
		res := posix.waitpid(r.lactase_children[i], &status, {.NOHANG})
		if res == 0 { continue }
		if res > 0 && posix.WIFEXITED(status) && posix.WEXITSTATUS(status) != 0 {
			log.warnf("lactase exited with status %d (see lactase.log in the runtime folder)", posix.WEXITSTATUS(status))
		}
		unordered_remove(&r.lactase_children, i)
	}
}

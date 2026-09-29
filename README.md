# milk

![milk](press/screenshot.png)

> A super lightweight, self-contained X11 desktop.

---

## Installation

On Arch Linux and its derivatives:

```sh
git clone https://github.com/mirvoxtm/milk.git
cd milk
./install.sh
```

The installer asks what you want, installs every dependency and also sets up
[Spoil](https://github.com/mirvoxtm/spoil), the file manager (Super+E), next to milk.
`./install.sh --yes` takes the defaults without asking.

Then log out and pick milk on the login screen. The first start walks you through the theme,
keyboard, wallpapers and bar. Change anything later with `milk settings`. It's as simple as that.

## Reasoning & Philosophy

In my vision, the window manager, the bar and the desktop should live in one program and share one
configuration file. All within one self-containing application that handles everything for the simplicity of the user. The user should also have the ability to style each workspace according to their needs - and he should have instant feedback when customizing his own instance.

Milk is a long vision for the perfect Window Manager i've had since i started using dwm in 2019.
This endeavour was inspired mainly by EmbargoTM's "Temenos".

User simplicity is the absolute priority for milk - I mean, have you ever seen a TWM that lets you change and test your keyboard without having to do a bunch of stuff in a config file? Yeah.

### Credits
- [dwm](https://dwm.suckless.org), by the suckless.org community: milk's window manager is mainly based upon a port of dwm 6.5 to Odin, released under the MIT/X Consortium License.
- [Noctalia](https://github.com/noctalia-dev/noctalia-shell), whose bar inspired the layout and look of milk's bar.
- [MangoWC](https://github.com/DreamMaoMao/mangowc), an inspiration for the animation in the window manager.
- [Temenos](https://github.com/EmbargoTM/Temenos), by EmbargoTM, for the original idea of giving each workspace its own identity.
- [Tabler Icons](https://tabler.io/icons) (MIT), the icon font used across the bar and panels.
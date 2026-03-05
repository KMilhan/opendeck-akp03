![Plugin Icon](assets/icon.png)

# OpenDeck N3-alike Plugin

An unofficial, linux only plugin for Mirabox N3-family devices

## Project note

This repository is a Zig port.
Original implementation by Andrey Viktorov.
Ported to Zig by Milhan Kim.
The port focuses on supporting a wider range of devices with a simpler implementation.

## OpenDeck version

Requires OpenDeck 2.5.0+

## Supported devices

> We aim supporting anything looks like N3. Report unsupported ones.

- Ajazz AKP03 (0300:1001)
- Ajazz AKP03E (0300:1002)
- Ajazz AKP03R (0300:1003)
- Ajazz AKP03E (rev. 2) (0300:3002)
- Mirabox N3 (6602:1002)
- Mirabox N3 (6603:1002)
- Mirabox N3EN (6603:1003)
- Soomfon Stream Controller SE (1500:3001)
- Mars Gaming MSD-TWO (0B00:1001)
- TreasLin N3 (5548:1001)
- Redragon Skyrider SS-551 (0200:2000)

## Platform support

- Linux only

## Installation

1. Download an archive from [releases](https://github.com/KMilhan/opendeck-akp03-zig/releases)
2. In OpenDeck: Plugins -> Install from file
3. Install [udev rules](./40-opendeck-akp03-zig.rules):

```sh
sudo install -Dm0644 40-opendeck-akp03-zig.rules /etc/udev/rules.d/40-opendeck-akp03-zig.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --action=add
sudo udevadm trigger --subsystem-match=hidraw --action=add
```

4. Unplug and plug again the device, then restart OpenDeck

## Adding new devices

Read [this wiki page](https://github.com/KMilhan/opendeck-akp03-zig/wiki/Adding-support-for-new-devices) for more information.

## Building

### Prerequisites

You'll need:

- Zig 0.15.2+
- hidapi (headers + library)
- libturbojpeg (turbojpeg.h + library)
- [just](https://just.systems)

On Arch Linux:

```sh
sudo pacman -S zig just hidapi libjpeg-turbo
```

### Building a release package

```sh
$ just package
```

`just package` builds the Linux binary and then runs the Zig packaging step.

Or directly after you have the binary in place (from `target/plugin-linux`):

```sh
zig build package
```

This produces `build/st.lynx.plugins.opendeck-akp03-zig.sdPlugin` and `opendeck-akp03-zig.plugin.zip` in the repository root.

### Notes

- If hidapi headers are not in the default include path, use `zig build -Dhidapi-include=/path/to/include`.
- If turbojpeg is installed under a non-default name, use `zig build -Dturbojpeg-lib=turbojpeg`.
- On Linux, prefer the native target (no `-Dtarget=...`) when linking against system `turbojpeg` to avoid glibc version mismatches.

## Acknowledgments

This plugin is heavily based on work by contributors of [elgato-streamdeck](https://github.com/streamduck-org/elgato-streamdeck).

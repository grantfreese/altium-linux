# License

Copyright (C) 2026 Grant Freese

This project is free software. You may redistribute it and/or modify it under the terms of either:

- the GNU General Public License as published by the Free Software Foundation, version 2 of the
  License, or (at your option) any later version (`GPL-2.0-or-later`), or
- the GNU Lesser General Public License as published by the Free Software Foundation, version 2.1
  of the License, or (at your option) any later version (`LGPL-2.1-or-later`),

at your option (SPDX: `GPL-2.0-or-later OR LGPL-2.1-or-later`).

This project is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License and the GNU Lesser General Public License for more details.

The full texts are in [`COPYING`](COPYING) (GNU General Public License, version 2) and
[`COPYING.LIB`](COPYING.LIB) (GNU Lesser General Public License, version 2.1).

## Wine-derived code

`src/d2d1-altium.patch` modifies the Direct2D implementation (`dlls/d2d1`) of
[Wine](https://www.winehq.org/). The changes made by the patch are offered under the same choice
of licenses as the rest of this project. The Wine code it modifies, and the context it quotes from
it, remain the copyright of the Wine project authors and are licensed under the GNU Lesser General
Public License, version 2.1 or later, which also permits using them under the GNU General Public
License, version 2 or later. A `d2d1.dll` built from Wine's source with the patch can therefore
be used under either license.

## Not included

This project contains no software, fonts or data from Altium or Microsoft. Altium Designer, its
installer and its license files come from Altium, under Altium's own license terms, and are not
covered by this license. Other components that setup downloads or installs, including the Wine
source, DXVK, packages from the Linux distribution, and the Microsoft runtimes and fonts installed
through winetricks, come from their publishers under their own license terms.

## Trademarks

Altium and Altium Designer are trademarks or registered trademarks of Altium or its affiliates.
This project is not affiliated with, endorsed by or supported by Altium.

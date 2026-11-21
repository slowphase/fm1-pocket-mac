# Third-party notices

## FM-1 Browser Simulator (Jake Handy), via FM-1 Pocket Player

`Sources/FM1Host/fm1host.c` is a C port of `src/rfm1.js` from Jake Handy's
[FM-1 Browser Simulator](https://github.com/jakehandy/fm1-browser-simulator), as kept in
[FM-1 Pocket Player](https://github.com/slowphase/fm1-pocket-player). MIT License:

Copyright (c) 2026 Jake Handy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## h1 (Jake Handy)

`Resources/h1.rfm1` is h1 0.2.1 ([jakehandy/h1](https://github.com/jakehandy/h1), commit 5b697e5), unchanged, as
FM-1 Pocket Player bundles it. MIT License, Copyright (c) 2026 Jake Handy (the same terms as above; the full text is
also inside the file's `rfm1.license.0` section).

## wasm3

`Sources/CWasm3` is [wasm3](https://github.com/wasm3/wasm3) v0.5.0 with two small changes listed in
`Sources/CWasm3/README.md`. MIT License, see `Sources/CWasm3/LICENSE`.

## fm1-emu (Joakim Eriksson), the emulator engine

https://github.com/joakimeriksson/fm1-emu, commit 09aeae3e9d78db52c3b9f5ceed93bd1120ccf444: its crates fm1-web,
fm1-soc, fm1-core and fm1-isa are compiled into the app unchanged (Emu/, Vendor/fm1emu). No other crates. It runs an
author's original FM-1 update package (.fwsc); the packages are their authors', fetched from their releases or
opened from disk, and are not part of the app.

```
MIT License

Copyright (c) 2026 Joakim Eriksson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## FM1 Editor's firmware directory (Ben Sparrow), via FM-1 Pocket Player

Some catalogue entries are listed from FM1 Editor's firmware directory (https://fm1-editor.com/firmware/, source at
https://github.com/benny-sparra/fm1-dx7-patch-importer), and their descriptions are FM1 Editor's own. The app shows
each such description with "Description from FM1 Editor" and its licence, and credits FM1 Editor in the About window.
The directory is used under the MIT License:

```
MIT License

Copyright (c) 2026 Ben Sparrow

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Firmware from the catalogue

The app does not include any other firmware. It downloads firmware that FM-1 Pocket Player publishes, on your
request, from FM-1 Pocket Player's own site. Each firmware is its authors' work under its own licence; the app shows
the licence and source link from the catalogue.

# References and attribution

Tandem uses native macOS frameworks. Protocol references and upstream license notices are listed below.

- [m1ddc](https://github.com/waydabber/m1ddc/tree/04d949794102eb8df01ad3681afff6464a3eede2), MIT: reference for IOAVService ABI, framebuffer/proxy association, MCDP29XX HDMI chip address, DDC packet layout and timing. The implementation here is independently written; DDC replies are validated for their headers, offsets and checksums. Its license is preserved below as attribution.
- [MonitorControl Arm64DDC](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift): reference for validating DDC reply headers and checksums. No source is bundled.
- Apple macOS frameworks supply AppKit, CoreGraphics, CoreAudio, ServiceManagement and IOKit. CoreDisplay, DisplayServices and IOAVService private symbols are resolved dynamically. These interfaces may change with macOS updates; unknown controls fail explicitly.

## m1ddc license

MIT License

Copyright (c) 2021 waydabber

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

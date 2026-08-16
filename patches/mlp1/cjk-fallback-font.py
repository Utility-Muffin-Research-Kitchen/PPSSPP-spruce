#!/usr/bin/env python3
"""Give the SDL text drawer a CJK fallback font on MLP1.

This build links SDL2_ttf (pkg-config finds it even though find_package is
disabled) but deliberately leaves fontconfig out, so PrepareFallbackFonts falls
through to a branch that fills nothing: upstream only populates
fallbackFontPaths_ under fontconfig or on macOS. The result is that every
non-Latin glyph draws as a square, including the endonyms in PPSSPP's own
language list -- so Chinese cannot even be identified to select it.

Take the candidate paths from the environment, because the launcher is what
knows where the release payload is mounted, and keep the shipped location as a
built-in so a direct invocation outside Jawaka still finds a font.
"""

from pathlib import Path
import sys


SRC = Path('Common/Render/Text/draw_text_sdl.cpp')

OLD = """#else
\t// We don't have a fallback font for this platform.
\t// Unsupported characters will be rendered as squares.
#endif"""

NEW = """#else
\t// UMRK: no fontconfig in this build, so upstream would leave
\t// fallbackFontPaths_ empty here and draw every non-Latin glyph as a square.
\t// PPSSPP_FALLBACK_FONTS is a colon-separated list of font files, most
\t// preferred first; the built-in path is the Droid Sans Fallback the Leaf
\t// release already ships, which is also the first name in the fontconfig
\t// preference list above.
\t{
\t\tstd::vector<std::string> candidates;

\t\tconst char *fontEnv = getenv("PPSSPP_FALLBACK_FONTS");
\t\tif (fontEnv && *fontEnv) {
\t\t\tstd::string list(fontEnv);
\t\t\tsize_t start = 0;
\t\t\twhile (start < list.size()) {
\t\t\t\tsize_t sep = list.find(':', start);
\t\t\t\tif (sep == std::string::npos) {
\t\t\t\t\tsep = list.size();
\t\t\t\t}
\t\t\t\tif (sep > start) {
\t\t\t\t\tcandidates.push_back(list.substr(start, sep - start));
\t\t\t\t}
\t\t\t\tstart = sep + 1;
\t\t\t}
\t\t}

\t\tcandidates.push_back(
\t\t\t"/mnt/sdcard/.system/leaf/platforms/mlp1/assets/pkg/chinese-fallback-font.ttf");

\t\tfor (size_t i = 0; i < candidates.size(); i++) {
\t\t\tif (!File::Exists(Path(candidates[i]))) {
\t\t\t\tcontinue;
\t\t\t}
\t\t\tbool duplicate = false;
\t\t\tfor (size_t j = 0; j < fallbackFontPaths_.size(); j++) {
\t\t\t\tif (fallbackFontPaths_[j].first == candidates[i]) {
\t\t\t\t\tduplicate = true;
\t\t\t\t\tbreak;
\t\t\t\t}
\t\t\t}
\t\t\tif (!duplicate) {
\t\t\t\tfallbackFontPaths_.push_back(std::make_pair(candidates[i], 0));
\t\t\t\tINFO_LOG(Log::G3D, "Fallback font registered: %s", candidates[i].c_str());
\t\t\t}
\t\t}

\t\tif (fallbackFontPaths_.empty()) {
\t\t\tWARN_LOG(Log::G3D, "No fallback font found; non-Latin text will draw as squares");
\t\t}
\t}
#endif"""

OLD_INCLUDE = """#include "ppsspp_config.h"
"""

NEW_INCLUDE = """#include "ppsspp_config.h"

#include <cstdlib>
"""


def replace_once(content: str, old: str, new: str, label: str) -> str:
    if old not in content:
        print(f"ERROR: MLP1 CJK fallback anchor missing: {label}", file=sys.stderr)
        raise SystemExit(1)
    return content.replace(old, new, 1)


def main() -> None:
    if not SRC.exists():
        print(f"ERROR: {SRC} not found", file=sys.stderr)
        raise SystemExit(1)

    content = SRC.read_text()
    content = replace_once(content, OLD_INCLUDE, NEW_INCLUDE, "cstdlib include")
    content = replace_once(content, OLD, NEW, "empty fallback branch")
    SRC.write_text(content)


if __name__ == '__main__':
    main()

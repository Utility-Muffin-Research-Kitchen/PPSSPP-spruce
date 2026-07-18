#!/usr/bin/env python3
"""Add coherent GLES and direct-display Vulkan rotation for MLP1.

The MLP1 panel is physically portrait while the handheld UI is landscape.
Reuse the established SDL/OpenGL rotation patch, then extend VK_KHR_display so
PPSSPP can select the swapped native mode and rotate in its own presentation
pipeline without an RGA copy on every frame.
"""

from pathlib import Path
import runpy
import sys


ROOT = Path(__file__).resolve().parents[1]
VULKAN_CONTEXT = Path("Common/GPU/Vulkan/VulkanContext.cpp")
SDL_MAIN = Path("SDL/SDLMain.cpp")
SDL_VULKAN_CONTEXT = Path("SDL/SDLVulkanGraphicsContext.cpp")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    if old not in content:
        print(f"ERROR: MLP1 Vulkan rotation anchor missing: {label}", file=sys.stderr)
        raise SystemExit(1)
    return content.replace(old, new, 1)


def patch_vulkan_context(path: Path) -> None:
    content = path.read_text()

    content = replace_once(
        content,
        """\t\tbool ret = false;
\t\tbool mode_found = false;

\t\tint i, j;""",
        """\t\tbool ret = false;
\t\tbool mode_found = false;
\t\tbool needs_rotation = false;

\t\tint i, j;""",
        "display state",
    )

    content = replace_once(
        content,
        """\t\t}

\t\t// Free the mode list now.
\t\tdelete [] mode_props;

\t\t// If there are no useable modes found on the display, error out""",
        """\t\t}

\t\t// MLP1's panel is native portrait. SDL exposes a logical landscape
\t\t// display after the platform rotation setup, so retry with swapped
\t\t// dimensions when the display has no exact landscape mode.
\t\tif (display_mode == VK_NULL_HANDLE) {
\t\t\tfor (i = 0; i < (int)mode_count; ++i) {
\t\t\t\tconst VkDisplayModePropertiesKHR *mode = &mode_props[i];
\t\t\t\tif (mode->parameters.visibleRegion.width == g_display.pixel_yres &&
\t\t\t\t    mode->parameters.visibleRegion.height == g_display.pixel_xres) {
\t\t\t\t\tdisplay_mode = mode->displayMode;
\t\t\t\t\tmode_found = true;
\t\t\t\t\tneeds_rotation = true;
\t\t\t\t\tINFO_LOG(Log::G3D,
\t\t\t\t\t\t"DISPLAY: selected native portrait mode %ux%u for logical %dx%d",
\t\t\t\t\t\tmode->parameters.visibleRegion.width,
\t\t\t\t\t\tmode->parameters.visibleRegion.height,
\t\t\t\t\t\tg_display.pixel_xres, g_display.pixel_yres);
\t\t\t\t\tbreak;
\t\t\t\t}
\t\t\t}
\t\t}

\t\t// Free the mode list now.
\t\tdelete [] mode_props;

\t\t// If there are no useable modes found on the display, error out""",
        "swapped display-mode fallback",
    )

    content = replace_once(
        content,
        """\t\t// Finally, create the vulkan surface.
\t\timage_size.width = g_display.pixel_xres;
\t\timage_size.height = g_display.pixel_yres;

\t\tdisplay.displayMode = display_mode;""",
        """\t\t// Finally, create the Vulkan surface at the physical panel extent.
\t\tif (needs_rotation) {
\t\t\timage_size.width = g_display.pixel_yres;
\t\t\timage_size.height = g_display.pixel_xres;
\t\t} else {
\t\t\timage_size.width = g_display.pixel_xres;
\t\t\timage_size.height = g_display.pixel_yres;
\t\t}

\t\tdisplay.displayMode = display_mode;""",
        "native surface extent",
    )

    content = replace_once(
        content,
        """\t} else {
\t\t// Let the OS rotate the image (potentially slower on many Android devices)
\t\tpreTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
\t}

\t// Only log transforms if relevant.""",
        """\t} else {
\t\t// Let the OS rotate the image (potentially slower on many Android devices)
\t\tpreTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
\t}

#if defined(VK_USE_PLATFORM_DISPLAY_KHR)
\t// Direct-display MLP1 surfaces expose the physical portrait extent and no
\t// hardware transform. Rotate through PPSSPP's presentation matrix instead.
\tif (preTransform == VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR &&
\t    swapChainExtent_.width < swapChainExtent_.height) {
\t\tg_display.rotation = DisplayRotation::ROTATE_270;
\t\tg_display.rot_matrix.setRotationZ270();
\t\tINFO_LOG(Log::G3D, "DISPLAY: applying MLP1 native portrait rotation");
\t}
#endif

\t// Only log transforms if relevant.""",
        "presentation rotation",
    )

    path.write_text(content)
    print(f"Patched {path}: MLP1 native Vulkan display rotation")


def patch_sdl_vulkan_window(main_path: Path, context_path: Path) -> None:
    content = main_path.read_text()
    content = replace_once(
        content,
        """\tGraphicsContext *graphicsContext = nullptr;
\tSDL_Window *window = nullptr;

\t// Switch away from Vulkan if not available.""",
        """\tGraphicsContext *graphicsContext = nullptr;
\tSDL_Window *window = nullptr;

\t// VK_KHR_display creates its surface directly and only needs SDL's KMSDRM
\t// window for input and WM metadata. Stock MLP1 SDL correctly rejects
\t// SDL_WINDOW_VULKAN for KMSDRM because it has no SDL Vulkan WSI backend.
\tint vulkanWindowMode = mode;
#if !defined(VK_USE_PLATFORM_DISPLAY_KHR)
\tvulkanWindowMode |= SDL_WINDOW_VULKAN;
#endif

\t// Switch away from Vulkan if not available.""",
        "direct-display SDL window flags",
    )
    if content.count("mode | SDL_WINDOW_VULKAN") != 2:
        print(
            "ERROR: expected two SDL Vulkan window-mode call sites",
            file=sys.stderr,
        )
        raise SystemExit(1)
    content = content.replace("mode | SDL_WINDOW_VULKAN", "vulkanWindowMode")
    main_path.write_text(content)

    content = context_path.read_text()
    content = replace_once(
        content,
        """\twindow = SDL_CreateWindow("Initializing Vulkan...", x, y, w, h, mode);
\tif (!window) {
\t\tfprintf(stderr, "Error creating SDL window: %s\\n", SDL_GetError());
\t\texit(1);
\t}""",
        """\twindow = SDL_CreateWindow("Initializing Vulkan...", x, y, w, h, mode);
\tif (!window) {
\t\t*error_message = "Error creating SDL window: ";
\t\t*error_message += SDL_GetError();
\t\treturn false;
\t}""",
        "recoverable SDL window failure",
    )
    content = replace_once(
        content,
        """\tvulkan_->SetCbGetDrawSize([window]() {
\t\tint w=1,h=1;
\t\tSDL_Vulkan_GetDrawableSize(window, &w, &h);
\t\treturn VkExtent2D {(uint32_t)w, (uint32_t)h};
\t});""",
        """#if defined(VK_USE_PLATFORM_DISPLAY_KHR)
\tvulkan_->SetCbGetDrawSize([]() {
\t\t// The MLP1 logical display is landscape while the direct-display
\t\t// surface uses the panel's physical portrait extent.
\t\treturn VkExtent2D {
\t\t\t(uint32_t)g_display.pixel_yres,
\t\t\t(uint32_t)g_display.pixel_xres,
\t\t};
\t});
#else
\tvulkan_->SetCbGetDrawSize([window]() {
\t\tint w=1,h=1;
\t\tSDL_Vulkan_GetDrawableSize(window, &w, &h);
\t\treturn VkExtent2D {(uint32_t)w, (uint32_t)h};
\t});
#endif""",
        "direct-display draw-size callback",
    )
    context_path.write_text(content)
    print("Patched SDL Vulkan startup: KMSDRM direct-display window")


if __name__ == "__main__":
    runpy.run_path(str(ROOT / "a30" / "display-rotation.py"), run_name="__main__")
    patch_vulkan_context(VULKAN_CONTEXT)
    patch_sdl_vulkan_window(SDL_MAIN, SDL_VULKAN_CONTEXT)

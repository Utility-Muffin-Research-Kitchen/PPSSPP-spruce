#!/usr/bin/env python3
"""Keep an explicit SDL --graphics backend across configuration loading.

PPSSPP parses --graphics before NativeInit(), but NativeInit() then loads
ppsspp.ini and can replace the requested backend.  MLP1 exposes Vulkan and
GLES as separate Jawaka cores backed by one binary, so the per-launch command
line must win without permanently changing the user's saved backend.
"""

from pathlib import Path
import sys


SDL_MAIN = Path("SDL/SDLMain.cpp")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    if old not in content:
        print(f"ERROR: MLP1 command-line backend anchor missing: {label}", file=sys.stderr)
        raise SystemExit(1)
    return content.replace(old, new, 1)


content = SDL_MAIN.read_text()
content = replace_once(
    content,
    """\tint force_gl_version = -1;

\tUint32 mode = 0;""",
    """\tint force_gl_version = -1;
\tint requested_gpu_backend = -1;
\tbool requested_software_rendering = false;

\tUint32 mode = 0;""",
    "requested backend state",
)
content = replace_once(
    content,
    """\t\t\tif (!strcmp(restOfOption, "vulkan")) {
\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::VULKAN;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t} else if (!strcmp(restOfOption, "software")) {""",
    """\t\t\tif (!strcmp(restOfOption, "vulkan")) {
\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::VULKAN;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t\trequested_gpu_backend = g_Config.iGPUBackend;
\t\t\t\trequested_software_rendering = false;
\t\t\t} else if (!strcmp(restOfOption, "software")) {""",
    "Vulkan option",
)
content = replace_once(
    content,
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = true;
\t\t\t} else if (!strcmp(restOfOption, "gles") || !strcmp(restOfOption, "opengl")) {""",
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = true;
\t\t\t\trequested_gpu_backend = g_Config.iGPUBackend;
\t\t\t\trequested_software_rendering = true;
\t\t\t} else if (!strcmp(restOfOption, "gles") || !strcmp(restOfOption, "opengl")) {""",
    "software option",
)
content = replace_once(
    content,
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t} else if (sscanf(restOfOption, "gles%lg", &val) == 1 || sscanf(restOfOption, "opengl%lg", &val) == 1) {""",
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t\trequested_gpu_backend = g_Config.iGPUBackend;
\t\t\t\trequested_software_rendering = false;
\t\t\t} else if (sscanf(restOfOption, "gles%lg", &val) == 1 || sscanf(restOfOption, "opengl%lg", &val) == 1) {""",
    "GLES option",
)
content = replace_once(
    content,
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t\tforce_gl_version = int(10.0 * val + 0.5);""",
    """\t\t\t\tg_Config.iGPUBackend = (int)GPUBackend::OPENGL;
\t\t\t\tg_Config.bSoftwareRendering = false;
\t\t\t\trequested_gpu_backend = g_Config.iGPUBackend;
\t\t\t\trequested_software_rendering = false;
\t\t\t\tforce_gl_version = int(10.0 * val + 0.5);""",
    "versioned GLES option",
)
content = replace_once(
    content,
    """\tNativeInit(remain_argc, (const char **)remain_argv, path, external_dir, nullptr);

\t// Use the setting from the config when initing the window.""",
    """\tNativeInit(remain_argc, (const char **)remain_argv, path, external_dir, nullptr);

\t// NativeInit loads ppsspp.ini after command-line parsing. Reapply an
\t// explicit backend for this process without changing the saved preference.
\tif (requested_gpu_backend >= 0) {
\t\tg_Config.iGPUBackend = requested_gpu_backend;
\t\tg_Config.bSoftwareRendering = requested_software_rendering;
\t\tg_Config.DoNotSaveSetting(&g_Config.iGPUBackend);
\t\tg_Config.DoNotSaveSetting(&g_Config.bSoftwareRendering);
\t}

\t// Use the setting from the config when initing the window.""",
    "post-config command-line override",
)
SDL_MAIN.write_text(content)
print(f"Patched {SDL_MAIN}: command-line graphics backend wins per launch")

#!/usr/bin/env python3
"""Expose deterministic benchmark savestates through PPSSPP's local debugger.

The benchmark debugger already provides game identity, input, and GPU statistics,
but upstream PPSSPP has no debugger request for save states.  Add two bounded,
game-scoped actions that use a dedicated file outside the user's numbered slots:

  game.savestate.save
  game.savestate.load

Both actions wait for PPSSPP's asynchronous save-state callback before replying.
The debugger remains disabled during normal launches; Leaf enables it temporarily
for controlled benchmarks.
"""

from pathlib import Path
import sys


GAME_SUBSCRIBER = Path("Core/Debugger/WebSocket/GameSubscriber.cpp")
GAME_SUBSCRIBER_HEADER = Path("Core/Debugger/WebSocket/GameSubscriber.h")


def replace_once(content: str, old: str, new: str, label: str) -> str:
    if old not in content:
        print(f"ERROR: MLP1 debugger savestate anchor missing: {label}", file=sys.stderr)
        raise SystemExit(1)
    return content.replace(old, new, 1)


content = GAME_SUBSCRIBER.read_text()
content = replace_once(
    content,
    """#include "Common/System/System.h"
#include "Core/Config.h"
#include "Core/Debugger/WebSocket/GameSubscriber.h"
#include "Core/Debugger/WebSocket/WebSocketUtils.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/System.h"
""",
    """#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>

#include "Common/File/FileUtil.h"
#include "Common/System/System.h"
#include "Core/Config.h"
#include "Core/Debugger/WebSocket/GameSubscriber.h"
#include "Core/Debugger/WebSocket/WebSocketUtils.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/SaveState.h"
#include "Core/System.h"
""",
    "includes",
)
content = replace_once(
    content,
    """\tmap["game.reset"] = &WebSocketGameReset;
\tmap["game.status"] = &WebSocketGameStatus;
\tmap["version"] = &WebSocketVersion;
""",
    """\tmap["game.reset"] = &WebSocketGameReset;
\tmap["game.status"] = &WebSocketGameStatus;
\tmap["game.savestate.save"] = &WebSocketGameSavestateSave;
\tmap["game.savestate.load"] = &WebSocketGameSavestateLoad;
\tmap["version"] = &WebSocketVersion;
""",
    "event registration",
)
content = replace_once(
    content,
    """// Reset emulation (game.reset)
""",
    r"""namespace {

struct DebuggerSavestateResult {
	std::mutex mutex;
	std::condition_variable condition;
	bool done = false;
	SaveState::Status status = SaveState::Status::FAILURE;
	std::string message;
};

Path DebuggerSavestatePath() {
	std::string prefix = SaveState::GetGamePrefix(g_paramSFO);
	for (char &value : prefix) {
		const unsigned char ch = static_cast<unsigned char>(value);
		if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		      (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.')) {
			value = '_';
		}
	}
	return GetSysDirectory(DIRECTORY_SAVESTATE) /
		("umrk-benchmark-" + prefix + ".ppst");
}

void FinishDebuggerSavestate(
	const std::shared_ptr<DebuggerSavestateResult> &result,
	SaveState::Status status,
	std::string_view message
) {
	{
		std::lock_guard<std::mutex> guard(result->mutex);
		result->status = status;
		result->message = std::string(message);
		result->done = true;
	}
	result->condition.notify_one();
}

bool WaitForDebuggerSavestate(
	DebuggerRequest &req,
	const std::shared_ptr<DebuggerSavestateResult> &result,
	const Path &path
) {
	std::unique_lock<std::mutex> lock(result->mutex);
	if (!result->condition.wait_for(lock, std::chrono::seconds(30), [&result]() {
		return result->done;
	})) {
		req.Fail("Savestate action timed out");
		return false;
	}
	if (result->status == SaveState::Status::FAILURE) {
		req.Fail(result->message.empty() ? "Savestate action failed" : result->message);
		return false;
	}

	JsonWriter &json = req.Respond();
	json.writeString(
		"status",
		result->status == SaveState::Status::SUCCESS ? "success" : "warning"
	);
	json.writeString("path", path.ToString());
	json.writeString("message", result->message);
	return true;
}

bool CheckDebuggerSavestateGame(DebuggerRequest &req) {
	if (PSP_GetBootState() != BootState::Complete) {
		req.Fail("Game not running");
		return false;
	}
	if (g_paramSFO.GetDiscID().empty()) {
		req.Fail("Running game has no disc ID");
		return false;
	}
	return true;
}

}  // namespace

// Save a dedicated benchmark state (game.savestate.save)
//
// No parameters. The response contains status, path, and message. This never
// writes a numbered user save-state slot.
void WebSocketGameSavestateSave(DebuggerRequest &req) {
	if (!CheckDebuggerSavestateGame(req))
		return;

	const Path path = DebuggerSavestatePath();
	const Path temporary = path.WithExtraExtension(".tmp");
	File::Delete(temporary, true);

	auto result = std::make_shared<DebuggerSavestateResult>();
	SaveState::Save(temporary, -1, [result, path, temporary](SaveState::Status status, std::string_view message) {
		std::string finalMessage(message);
		if (status != SaveState::Status::FAILURE) {
			File::Delete(path, true);
			if (!File::Rename(temporary, path)) {
				status = SaveState::Status::FAILURE;
				finalMessage = "Could not promote benchmark savestate";
			}
		}
		FinishDebuggerSavestate(result, status, finalMessage);
	});
	WaitForDebuggerSavestate(req, result, path);
}

// Load the dedicated benchmark state (game.savestate.load)
//
// No parameters. The response contains status, path, and message.
void WebSocketGameSavestateLoad(DebuggerRequest &req) {
	if (!CheckDebuggerSavestateGame(req))
		return;

	const Path path = DebuggerSavestatePath();
	if (!File::Exists(path)) {
		req.Fail("Benchmark savestate does not exist");
		return;
	}

	auto result = std::make_shared<DebuggerSavestateResult>();
	SaveState::Load(path, -1, [result](SaveState::Status status, std::string_view message) {
		FinishDebuggerSavestate(result, status, message);
	});
	WaitForDebuggerSavestate(req, result, path);
}

// Reset emulation (game.reset)
""",
    "savestate handlers",
)
GAME_SUBSCRIBER.write_text(content)

header = GAME_SUBSCRIBER_HEADER.read_text()
header = replace_once(
    header,
    """void WebSocketGameReset(DebuggerRequest &req);
void WebSocketGameStatus(DebuggerRequest &req);
void WebSocketVersion(DebuggerRequest &req);
""",
    """void WebSocketGameReset(DebuggerRequest &req);
void WebSocketGameStatus(DebuggerRequest &req);
void WebSocketGameSavestateSave(DebuggerRequest &req);
void WebSocketGameSavestateLoad(DebuggerRequest &req);
void WebSocketVersion(DebuggerRequest &req);
""",
    "handler declarations",
)
GAME_SUBSCRIBER_HEADER.write_text(header)

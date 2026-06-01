package editor

import ye "../Engine"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import path "core:path/filepath"

//game_config_path := "App/Config/game.json"
run_editor := true
ODIN_DEBUG :: #config(ODIN_DEBUG, false)

main :: proc() {
	// 1. Get the directory where ymir_editor.exe actually lives
	exe_dir, _ := os.get_executable_directory(context.temp_allocator)

	// 2. Construct the absolute path to the config
	// This results in: C:/.../Build/editor/App/Config/game.json
	game_config_path, _ := path.join({exe_dir, "App", "Config", "game.json"})

	when ODIN_DEBUG {
		context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	} else {
		context.logger = log.create_console_logger(opt = {.Level})
	}
	defer log.destroy_console_logger(context.logger)

	when ODIN_DEBUG {
		fmt.println("Starting editor in debug mode")
		fmt.printf("Loading config from: %s\n", game_config_path)

		// Verify file exists before passing to runtime
		if !os.exists(game_config_path) {
			fmt.eprintf("ERROR: Config file not found at: %s\n", game_config_path)
			return
		}
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
				for _, entry in track.allocation_map {
					log.debugf("%v bytes @ %v", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
				for entry in track.bad_free_array {
					log.debugf("%p @ %v", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	runtime, err := ye.boot_runtime(game_config_path)
	if !err {
		return
	}
	runtime.editor_ui_enabled = true
	defer ye.shutdown_runtime(&runtime)

	register_with_vulkan()

	init_ok, _ := ye.init_engine(runtime.config, debug = ODIN_DEBUG)
	if !init_ok {
		log.error("Editor engine initialization failed, exiting.")
		return
	}

	fmt.println("Starting in editor mode")
	for run_editor {
		if ye.should_quit(&runtime) {
			run_editor = false
			break
		}
		ye.draw_frame(&runtime)
	}
}

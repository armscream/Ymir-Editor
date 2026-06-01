
package editor


import vk "/../Engine/Backend/Vulkan"
import im "/../Engine/Libs/imgui"
import gz "/../Engine/Libs/imguizmo"
import ymath "/../Engine/core"
import Asset_Converter "/Asset_Converter"
import json "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import la "core:math/linalg"
import "core:os"
import "core:strings"
import win "core:sys/windows"

BROWSER_PANEL_DEFAULT_HEIGHT :: f32(220)

// Persistent editor config path
EDITOR_CONFIG_PATH :: "Editor/Config/editor_config.json"

Editor_Config :: struct {
	import_options: Import_Convert_Options,
}

// Persistent import options (static)
@(private)
editor_config_persistent: Editor_Config
@(private)
import_options_loaded: bool = false

// Load persistent editor config from JSON
load_editor_config :: proc() {
	data, err := os.read_entire_file(EDITOR_CONFIG_PATH, context.allocator)
	if err == nil && data != nil {
		cfg: Editor_Config
		if json.unmarshal(data, &cfg) == nil {
			editor_config_persistent = cfg
			import_options_loaded = true
		}
		delete(data)
	}
}

// Save persistent editor config to JSON
save_editor_config :: proc(cfg: Editor_Config) {
	buf, _ := json.marshal(cfg)
	if buf != nil {
		_ = os.write_entire_file(EDITOR_CONFIG_PATH, buf)
		delete(buf)
	}
}

Level_UI_Action :: enum {
	None,
	Load_Ok,
	Load_Failed,
	Save_Ok,
	Save_Failed,
}

Runtime_Game_Config_View :: struct {
	renderer_backend: string,
	editor_backend:   string,
	game_name:        string,
	tonemap:          string,
	keybinds_path:    string,
	current_level:    string,
	levels:           []string,
	window_x:         i32,
	window_y:         i32,
	window_width:     i32,
	window_height:    i32,
	fullscreen:       bool,
}

MATERIAL_SLOT_ASSET_PAYLOAD_TYPE :: "YMIR_ASSET_PATH"

Dragged_Asset_Payload :: struct {
	path: string,
}

Asset_UI_Action :: enum {
	None,
	Import_Ok,
	Import_Failed,
	Export_Ok,
	Export_Failed,
	Add_Ok,
	Add_Failed,
}

Import_Convert_Options :: struct {
	lod_count:             i32,
	max_meshlet_vertices:  i32,
	max_meshlet_triangles: i32,
	generate_meshlets:     bool,
	generate_collision:    bool,
	optimize_overdraw:     bool,
	use_strip_cache:       bool,
}

Editor_UI_Params :: struct {
	display_size:             im.Vec2,
	runtime_config:           ^Runtime_Game_Config_View,
	scene:                    ^vk.Scene,
	view:                     la.Matrix4x4f32,
	proj:                     la.Matrix4x4f32,
	load_level:               vk.Editor_Load_Level_Proc,
	save_level:               vk.Editor_Save_Level_Proc,
	delete_node:              vk.Editor_Delete_Node_Proc,
	add_mesh_node:            vk.Editor_Add_Mesh_Node_Proc,
	set_global_atlas_mode:    vk.Editor_Set_Global_Atlas_Mode_Proc,
	assign_slot_material:     vk.Editor_Assign_Node_Material_Slot_Proc,
	set_slot_material_policy: vk.Editor_Set_Node_Material_Policy_Proc,
}

Transform_Space :: enum {
	Local,
	World,
}

@(private = "file")
Browser_State :: struct {
	dir_root:         string, // owned
	dir_current:      string, // owned
	file_entries:     []os.File_Info,
	file_entries_dir: string, // owned — tracks which dir was last loaded
	asset_selected:   string, // owned
	search_buf:       [256]byte,
	selected_node:    i32,
	initialized:      bool,
}

@(private = "file")
g: Browser_State

Transform_Edit_Command :: struct {
	old_local:  vk.Transform,
	new_local:  vk.Transform,
	node_index: i32,
}

Scene_State_Snapshot :: struct {
	local_transforms:        [dynamic]vk.Transform,
	world_transforms:        [dynamic]vk.Transform,
	transform_dirty:         [dynamic]bool,
	subtree_dirty:           [dynamic]bool,
	hierarchy:               [dynamic]vk.Hierarchy,
	mesh_for_node:           [dynamic]u32,
	material_for_node:       [dynamic]u32,
	material_slots_for_node: [dynamic][dynamic]u32,
	name_for_node:           [dynamic]u32,
	node_names:              [dynamic]string,
}

Scene_Edit_Command :: struct {
	before:          Scene_State_Snapshot,
	after:           Scene_State_Snapshot,
	selected_before: i32,
	selected_after:  i32,
}

Edit_Command :: union {
	Transform_Edit_Command,
	Scene_Edit_Command,
}

@(private = "file")
Edit_History :: struct {
	commands:     [dynamic]Edit_Command,
	edit_before:  vk.Transform,
	cursor:       i32,
	max_commands: i32,
	edit_node:    i32,
	edit_active:  bool,
}

@(private = "file")
g_history: Edit_History

@(private = "file")
g_world_gizmo_interacting: bool

@(private = "file")
is_supported_material_asset_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	if strings.has_suffix(lower, ".ymat.json") {
		return true
	}
	return(
		strings.has_suffix(lower, ".mtl") ||
		strings.has_suffix(lower, ".png") ||
		strings.has_suffix(lower, ".jpg") ||
		strings.has_suffix(lower, ".jpeg") ||
		strings.has_suffix(lower, ".tga") ||
		strings.has_suffix(lower, ".bmp") \
	)
}

@(private = "file")
display_asset_name :: proc(path: string) -> string {
	if len(path) == 0 {
		return ""
	}

	name := path
	last_slash := strings.last_index(name, "/")
	last_backslash := strings.last_index(name, "\\")
	if last_backslash > last_slash {
		last_slash = last_backslash
	}
	if last_slash >= 0 && last_slash + 1 < len(name) {
		name = name[last_slash + 1:]
	}

	return name
}

@(private = "file")
transform_nearly_equal :: proc(a, b: vk.Transform, epsilon: f32 = 1e-4) -> bool {
	if math.abs(a.position.x - b.position.x) > epsilon do return false
	if math.abs(a.position.y - b.position.y) > epsilon do return false
	if math.abs(a.position.z - b.position.z) > epsilon do return false

	if math.abs(a.scale.x - b.scale.x) > epsilon do return false
	if math.abs(a.scale.y - b.scale.y) > epsilon do return false
	if math.abs(a.scale.z - b.scale.z) > epsilon do return false

	if math.abs(a.rotation.x - b.rotation.x) > epsilon do return false
	if math.abs(a.rotation.y - b.rotation.y) > epsilon do return false
	if math.abs(a.rotation.z - b.rotation.z) > epsilon do return false
	if math.abs(a.rotation.w - b.rotation.w) > epsilon do return false

	return true
}

@(private = "file")
scene_snapshot_delete :: proc(snapshot: ^Scene_State_Snapshot) {
	if snapshot == nil {
		return
	}

	delete(snapshot.local_transforms)
	delete(snapshot.world_transforms)
	delete(snapshot.transform_dirty)
	delete(snapshot.subtree_dirty)
	delete(snapshot.hierarchy)
	delete(snapshot.mesh_for_node)
	delete(snapshot.material_for_node)
	for slots in snapshot.material_slots_for_node {
		delete(slots)
	}
	delete(snapshot.material_slots_for_node)
	delete(snapshot.name_for_node)

	for name in snapshot.node_names {
		delete(name)
	}
	delete(snapshot.node_names)

	snapshot^ = {}
}

@(private = "file")
scene_snapshot_from_scene :: proc(scene: ^vk.Scene) -> Scene_State_Snapshot {
	if scene == nil {
		return {}
	}

	snapshot: Scene_State_Snapshot

	snapshot.local_transforms = make([dynamic]vk.Transform, len(scene.local_transforms))
	copy(snapshot.local_transforms[:], scene.local_transforms[:])

	snapshot.world_transforms = make([dynamic]vk.Transform, len(scene.world_transforms))
	copy(snapshot.world_transforms[:], scene.world_transforms[:])

	snapshot.transform_dirty = make([dynamic]bool, len(scene.transform_dirty))
	copy(snapshot.transform_dirty[:], scene.transform_dirty[:])

	snapshot.subtree_dirty = make([dynamic]bool, len(scene.subtree_dirty))
	copy(snapshot.subtree_dirty[:], scene.subtree_dirty[:])

	snapshot.hierarchy = make([dynamic]vk.Hierarchy, len(scene.hierarchy))
	copy(snapshot.hierarchy[:], scene.hierarchy[:])

	snapshot.mesh_for_node = make([dynamic]u32, len(scene.mesh_for_node))
	copy(snapshot.mesh_for_node[:], scene.mesh_for_node[:])

	snapshot.material_for_node = make([dynamic]u32, len(scene.material_for_node))
	copy(snapshot.material_for_node[:], scene.material_for_node[:])

	snapshot.material_slots_for_node = make(
		[dynamic][dynamic]u32,
		len(scene.material_slots_for_node),
	)
	for slots, i in scene.material_slots_for_node {
		slots_copy := make([dynamic]u32, len(slots))
		if len(slots_copy) > 0 {
			copy(slots_copy[:], slots[:])
		}
		snapshot.material_slots_for_node[i] = slots_copy
	}

	snapshot.name_for_node = make([dynamic]u32, len(scene.name_for_node))
	copy(snapshot.name_for_node[:], scene.name_for_node[:])

	snapshot.node_names = make([dynamic]string, len(scene.node_names))
	for name, i in scene.node_names {
		snapshot.node_names[i] = strings.clone(name)
	}

	return snapshot
}

@(private = "file")
scene_apply_snapshot :: proc(scene: ^vk.Scene, snapshot: Scene_State_Snapshot) {
	if scene == nil {
		return
	}

	for name in scene.node_names {
		delete(name)
	}

	delete(scene.local_transforms)
	delete(scene.world_transforms)
	delete(scene.transform_dirty)
	delete(scene.subtree_dirty)
	delete(scene.hierarchy)
	delete(scene.mesh_for_node)
	delete(scene.material_for_node)
	for slots in scene.material_slots_for_node {
		delete(slots)
	}
	delete(scene.material_slots_for_node)
	delete(scene.name_for_node)
	delete(scene.node_names)

	scene.local_transforms = make([dynamic]vk.Transform, len(snapshot.local_transforms))
	copy(scene.local_transforms[:], snapshot.local_transforms[:])

	scene.world_transforms = make([dynamic]vk.Transform, len(snapshot.world_transforms))
	copy(scene.world_transforms[:], snapshot.world_transforms[:])

	scene.transform_dirty = make([dynamic]bool, len(snapshot.transform_dirty))
	copy(scene.transform_dirty[:], snapshot.transform_dirty[:])

	scene.subtree_dirty = make([dynamic]bool, len(snapshot.subtree_dirty))
	copy(scene.subtree_dirty[:], snapshot.subtree_dirty[:])

	scene.hierarchy = make([dynamic]vk.Hierarchy, len(snapshot.hierarchy))
	copy(scene.hierarchy[:], snapshot.hierarchy[:])

	scene.mesh_for_node = make([dynamic]u32, len(snapshot.mesh_for_node))
	copy(scene.mesh_for_node[:], snapshot.mesh_for_node[:])

	scene.material_for_node = make([dynamic]u32, len(snapshot.material_for_node))
	copy(scene.material_for_node[:], snapshot.material_for_node[:])

	scene.material_slots_for_node = make(
		[dynamic][dynamic]u32,
		len(snapshot.material_slots_for_node),
	)
	for slots, i in snapshot.material_slots_for_node {
		slots_copy := make([dynamic]u32, len(slots))
		if len(slots_copy) > 0 {
			copy(slots_copy[:], slots[:])
		}
		scene.material_slots_for_node[i] = slots_copy
	}

	scene.name_for_node = make([dynamic]u32, len(snapshot.name_for_node))
	copy(scene.name_for_node[:], snapshot.name_for_node[:])

	scene.node_names = make([dynamic]string, len(snapshot.node_names))
	for name, i in snapshot.node_names {
		scene.node_names[i] = strings.clone(name)
	}
}

@(private = "file")
history_free_command :: proc(command: ^Edit_Command) {
	if command == nil {
		return
	}

	switch &cmd in command^ {
	case Scene_Edit_Command:
		scene_snapshot_delete(&cmd.before)
		scene_snapshot_delete(&cmd.after)
	case Transform_Edit_Command:
	}
}

@(private = "file")
history_push_command :: proc(command: Edit_Command) {
	if g_history.cursor + 1 < i32(len(g_history.commands)) {
		for i := g_history.cursor + 1; i < i32(len(g_history.commands)); i += 1 {
			history_free_command(&g_history.commands[i])
		}
		resize(&g_history.commands, g_history.cursor + 1)
	}

	append(&g_history.commands, command)
	g_history.cursor = i32(len(g_history.commands)) - 1

	if g_history.max_commands > 0 && i32(len(g_history.commands)) > g_history.max_commands {
		history_free_command(&g_history.commands[0])
		copy(g_history.commands[0:], g_history.commands[1:])
		pop(&g_history.commands)
		g_history.cursor = i32(len(g_history.commands)) - 1
	}
}

@(private = "file")
history_clear :: proc() {
	if g_history.commands != nil {
		for i := 0; i < len(g_history.commands); i += 1 {
			history_free_command(&g_history.commands[i])
		}
		delete(g_history.commands)
		g_history.commands = nil
	}
	g_history.cursor = -1
	g_history.edit_active = false
	g_history.edit_node = -1
	g_history.edit_before = {}
}

@(private = "file")
history_push_transform_edit :: proc(cmd: Transform_Edit_Command) {
	if transform_nearly_equal(cmd.old_local, cmd.new_local) {
		return
	}
	history_push_command(Edit_Command(cmd))
}

@(private = "file")
history_push_scene_edit :: proc(command: Scene_Edit_Command) {
	history_push_command(Edit_Command(command))
}

@(private = "file")
history_begin_active_edit :: proc(scene: ^vk.Scene, node: i32) {
	if scene == nil || !selected_node_valid(scene, node) {
		return
	}
	if g_history.edit_active {
		return
	}
	g_history.edit_active = true
	g_history.edit_node = node
	g_history.edit_before = scene.local_transforms[node]
}

@(private = "file")
history_commit_active_edit_if_requested :: proc(scene: ^vk.Scene, commit_now: bool) {
	if !g_history.edit_active || scene == nil || !commit_now {
		return
	}

	node := g_history.edit_node
	if selected_node_valid(scene, node) {
		after := scene.local_transforms[node]
		history_push_transform_edit(
			Transform_Edit_Command {
				node_index = node,
				old_local = g_history.edit_before,
				new_local = after,
			},
		)
	}

	g_history.edit_active = false
	g_history.edit_node = -1
}

@(private = "file")
history_cancel_active_edit :: proc() {
	g_history.edit_active = false
	g_history.edit_node = -1
}

@(private = "file")
history_undo :: proc(scene: ^vk.Scene, selected_node: ^i32) -> bool {
	if scene == nil || g_history.cursor < 0 || g_history.cursor >= i32(len(g_history.commands)) {
		return false
	}

	cmd := g_history.commands[g_history.cursor]
	g_history.cursor -= 1

	switch &edit in cmd {
	case Transform_Edit_Command:
		if !selected_node_valid(scene, edit.node_index) {
			return false
		}
		vk.scene_set_local_transform(scene, edit.node_index, edit.old_local)
		selected_node^ = edit.node_index
		return true
	case Scene_Edit_Command:
		scene_apply_snapshot(scene, edit.before)
		selected_node^ = edit.selected_before
		if !selected_node_valid(scene, selected_node^) {
			selected_node^ = -1
		}
		return true
	}

	return false
}

@(private = "file")
history_redo :: proc(scene: ^vk.Scene, selected_node: ^i32) -> bool {
	next := g_history.cursor + 1
	if scene == nil || next < 0 || next >= i32(len(g_history.commands)) {
		return false
	}

	cmd := g_history.commands[next]
	g_history.cursor = next

	switch &edit in cmd {
	case Transform_Edit_Command:
		if !selected_node_valid(scene, edit.node_index) {
			return false
		}
		vk.scene_set_local_transform(scene, edit.node_index, edit.new_local)
		selected_node^ = edit.node_index
		return true
	case Scene_Edit_Command:
		scene_apply_snapshot(scene, edit.after)
		selected_node^ = edit.selected_after
		if !selected_node_valid(scene, selected_node^) {
			selected_node^ = -1
		}
		return true
	}

	return false
}

@(private = "file")
apply_world_transform_to_node :: proc(scene: ^vk.Scene, node: i32, world_t: vk.Transform) {
	parent := scene.hierarchy[node].parent
	if parent >= 0 && parent < i32(len(scene.world_transforms)) {
		parent_inv := vk.transform_inverse(scene.world_transforms[parent])
		local_updated := vk.transform_compose(parent_inv, world_t)
		vk.scene_set_local_transform(scene, node, local_updated)
	} else {
		vk.scene_set_local_transform(scene, node, world_t)
	}
}

@(private = "file")
apply_transform_components_to_node :: proc(
	scene: ^vk.Scene,
	node: i32,
	space: Transform_Space,
	position: [3]f32,
	rotation_quat: [4]f32,
	scale: [3]f32,
) {
	rotation_quat_local := ymath.quat_normalize(rotation_quat)
	scale_local := scale
	if scale_local.x == 0 && scale_local.y == 0 && scale_local.z == 0 {
		scale_local = [3]f32{1, 1, 1}
	}

	updated := vk.Transform {
		position = position,
		rotation = ymath.quat_from_xyzw_f32(
			rotation_quat_local.x,
			rotation_quat_local.y,
			rotation_quat_local.z,
			rotation_quat_local.w,
		),
		scale    = scale_local,
	}
	vk.scene_set_local_transform(scene, node, updated)
}

@(private = "file")
transform_components_from_local :: proc(
	t: vk.Transform,
) -> (
	position: [3]f32,
	rotation_quat: [4]f32,
	scale: [3]f32,
) {
	position = [3]f32{t.position.x, t.position.y, t.position.z}
	rotation_quat = [4]f32{t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w}
	scale = [3]f32{t.scale.x, t.scale.y, t.scale.z}
	return
}

@(private = "file")
transform_components_from_world :: proc(
	t: vk.Transform,
) -> (
	position: [3]f32,
	rotation_quat: [4]f32,
	scale: [3]f32,
) {
	position = [3]f32{t.position.x, t.position.y, t.position.z}
	rotation_quat = [4]f32{t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w}
	scale = [3]f32{t.scale.x, t.scale.y, t.scale.z}
	return
}

@(private = "file")
editor_handle_history_shortcuts :: proc(scene: ^vk.Scene, selected_node: ^i32) {
	if scene == nil {
		return
	}

	io := im.get_io()
	if io.want_text_input {
		return
	}

	if io.key_ctrl && io.key_shift && im.is_key_pressed(.Z, false) {
		_ = history_redo(scene, selected_node)
		return
	}

	if io.key_ctrl && im.is_key_pressed(.Y, false) {
		_ = history_redo(scene, selected_node)
		return
	}

	if io.key_ctrl && !io.key_shift && im.is_key_pressed(.Z, false) {
		_ = history_undo(scene, selected_node)
		return
	}
}

// editor_browser_init sets the root path for the directory panel.
// Safe to call every frame — only initialises once.
editor_browser_init :: proc(root_path: string = ".") {
	if g.initialized do return
	g.dir_root = strings.clone(root_path)
	g.dir_current = strings.clone(root_path)
	g.selected_node = -1
	g_history.max_commands = 256
	g_history.cursor = -1
	g_history.edit_node = -1
	g.initialized = true
}

// editor_browser_shutdown releases all owned memory.  Call on editor exit.
editor_browser_shutdown :: proc() {
	delete(g.dir_root)
	delete(g.dir_current)
	delete(g.asset_selected)
	delete(g.file_entries_dir)
	if g.file_entries != nil {
		os.file_info_slice_delete(g.file_entries, context.allocator)
	}
	history_clear()
	g = {}
}

@(private = "file")
navigate_to :: proc(path: string) {
	if g.dir_current == path do return
	delete(g.dir_current)
	g.dir_current = strings.clone(path)
	reload_file_entries()
}

@(private = "file")
reload_file_entries :: proc() {
	if g.file_entries != nil {
		os.file_info_slice_delete(g.file_entries, context.allocator)
		g.file_entries = nil
	}
	delete(g.file_entries_dir)
	entries, err := os.read_all_directory_by_path(g.dir_current, context.allocator)
	if err == nil {
		g.file_entries = entries
	}
	g.file_entries_dir = strings.clone(g.dir_current)
}

// draw_dir_node renders one directory entry as a collapsible tree node.
// Children (sub-directories) are read from disk only when the node is open.
@(private = "file")
draw_dir_node :: proc(path: string, name: string) {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	has_subdirs := false
	if err == nil {
		for e in entries {
			if e.type == .Directory {
				has_subdirs = true
				break
			}
		}
	}
	defer if err == nil {
		os.file_info_slice_delete(entries, context.allocator)
	}

	flags: im.Tree_Node_Flags = {.Open_On_Arrow, .Span_Avail_Width}
	if !has_subdirs {flags += {.Leaf}}
	if path == g.dir_current {flags += {.Selected}}

	opened := im.tree_node_ex(fmt.ctprintf("%s", name), flags)

	if im.is_item_clicked() && !im.is_item_toggled_open() {
		navigate_to(path)
	}

	if opened {
		if err == nil {
			for e in entries {
				if e.type == .Directory {
					draw_dir_node(e.fullpath, e.name)
				}
			}
		}
		im.tree_pop()
	}
}

@(private = "file")
truncate_hierarchy_label :: proc(name: string, max_chars: int = 40) -> string {
	if len(name) <= max_chars {
		return name
	}
	if max_chars <= 3 {
		return name[:max_chars]
	}
	return strings.concatenate({name[:max_chars - 3], "..."}, context.temp_allocator)
}

@(private = "file")
render_scene_tree_ui :: proc(scene: ^vk.Scene, #any_int node: i32, selected_node: ^i32) -> i32 {
	name := vk.scene_get_node_name(scene, node)
	label := len(name) == 0 ? "NO NODE" : name
	display_label := truncate_hierarchy_label(label)
	is_leaf := scene.hierarchy[node].first_child < 0
	flags: im.Tree_Node_Flags = is_leaf ? {.Leaf, .Bullet} : {}

	if node == selected_node^ {
		flags += {.Selected}
	}

	// Make the node span the entire width
	flags += {.Span_Full_Width, .Frame_Padding}

	is_opened := im.tree_node_ex_ptr(
		&scene.hierarchy[node],
		flags,
		"%s",
		cstring(raw_data(display_label)),
	)

	// Check for clicks in the entire row area
	was_clicked := im.is_item_clicked()

	im.push_id_int(node)
	{
		if was_clicked {
			log.debugf("Selected node: %d (%s)", node, label)
			selected_node^ = node
		}

		if is_opened {
			for ch := scene.hierarchy[node].first_child;
			    ch != -1;
			    ch = scene.hierarchy[ch].next_sibling {
				if sub_node := render_scene_tree_ui(scene, ch, selected_node); sub_node > -1 {
					selected_node^ = sub_node
				}
			}
			im.tree_pop()
		}
	}
	im.pop_id()

	return selected_node^
}

@(private = "file")
selected_node_valid :: proc(scene: ^vk.Scene, node: i32) -> bool {
	if scene == nil {
		return false
	}
	return node >= 0 && node < i32(len(scene.hierarchy))
}

@(private = "file")
editor_get_node_material_slot_name :: proc(
	scene: ^vk.Scene,
	node_index: i32,
	slot_index: i32,
) -> string {
	if scene == nil || node_index < 0 || node_index >= i32(len(scene.mesh_for_node)) {
		return ""
	}

	mesh_index := scene.mesh_for_node[node_index]
	if mesh_index == vk.NO_MESH || int(mesh_index) >= len(scene.meshes) {
		return ""
	}

	mesh := scene.meshes[mesh_index]
	if slot_index < 0 || slot_index >= i32(len(mesh.surfaces)) {
		return ""
	}

	slot_name := mesh.surfaces[slot_index].slot_name
	if len(slot_name) > 0 {
		return slot_name
	}

	return fmt.tprintf("slot_%d", slot_index)
}

@(private = "file")
draw_world_gizmo :: proc(scene: ^vk.Scene, selected_node: i32, view, proj: la.Matrix4x4f32) {
	if scene == nil || !selected_node_valid(scene, selected_node) {
		g_world_gizmo_interacting = false
		return
	}

	@(static) operation: gz.Operation = .Translate
	@(static) mode: gz.Mode = .World
	@(static) was_using_last_frame := false

	im.text("Viewport Gizmo")
	if im.small_button("Move") do operation = .Translate
	im.same_line()
	if im.small_button("Rotate") do operation = .Rotate
	im.same_line()
	if im.small_button("Scale") do operation = .Scale

	im.same_line()
	im.text("|")
	im.same_line()
	if im.small_button("G Local") do mode = .Local
	im.same_line()
	if im.small_button("G World") do mode = .World

	view_16 := ymath.matrix4x4_to_mat16_f32(view)
	// ImGuizmo expects a non-flipped projection; engine projection is Vulkan-flipped on Y.
	gizmo_proj := proj
	gizmo_proj[1][1] = -gizmo_proj[1][1]
	proj_16 := ymath.matrix4x4_to_mat16_f32(gizmo_proj)
	world_matrix := vk.transform_to_matrix(scene.world_transforms[selected_node])
	world_16 := ymath.matrix4x4_to_mat16_f32(world_matrix)

	if !ymath.mat16_is_valid_f32(view_16) || !ymath.mat16_is_valid_f32(proj_16) {
		g_world_gizmo_interacting = false
		return
	}
	if !ymath.mat16_is_valid_f32(world_16) {
		world_16 = ymath.mat16_identity_f32()
	}

	vp := im.get_main_viewport()
	gz.set_imgui_context(cast(rawptr)im.get_current_context())
	gz.begin_frame()
	gz.set_orthographic(false)
	gz.set_drawlist(cast(rawptr)im.get_foreground_draw_list(vp))
	gz.set_rect(vp.work_pos.x, vp.work_pos.y, vp.work_size.x, vp.work_size.y)

	manip_mode := mode
	if operation == .Rotate || operation == .Scale {
		// ImGuizmo is unstable in world mode for rotate/scale with some transforms.
		manip_mode = .Local
	}

	_ = gz.manipulate(&view_16[0], &proj_16[0], operation, manip_mode, &world_16[0])

	using_now := gz.is_using()
	over_now := gz.is_over()
	g_world_gizmo_interacting = using_now || over_now

	if using_now {
		if !ymath.mat16_is_valid_f32(world_16) {
			g_world_gizmo_interacting = false
			return
		}

		history_begin_active_edit(scene, selected_node)

		translation := [3]f32{}
		rotation_deg := [3]f32{}
		scale := [3]f32{}
		gz.decompose_matrix_to_components(
			&world_16[0],
			&translation[0],
			&rotation_deg[0],
			&scale[0],
		)

		if scale.x == 0 && scale.y == 0 && scale.z == 0 {
			scale = [3]f32{1, 1, 1}
		}

		world_updated := vk.Transform {
			position = translation,
			rotation = ymath.quat_from_euler_degrees_xyz_f32(rotation_deg),
			scale    = scale,
		}
		apply_world_transform_to_node(scene, selected_node, world_updated)
	}

	if was_using_last_frame && !using_now {
		history_commit_active_edit_if_requested(scene, true)
	}
	was_using_last_frame = using_now
}

@(private = "file")
draw_selected_node_gizmo_ui :: proc(
	scene: ^vk.Scene,
	selected_node: i32,
	delete_node: vk.Editor_Delete_Node_Proc,
	assign_slot_material: vk.Editor_Assign_Node_Material_Slot_Proc,
	set_slot_material_policy: vk.Editor_Set_Node_Material_Policy_Proc,
	view, proj: la.Matrix4x4f32,
) -> bool {

	if scene == nil {
		log.errorf("[draw_selected_node_gizmo_ui] scene is nil!")
		return false
	}
	if !selected_node_valid(scene, selected_node) || i32(selected_node) >= i32(len(scene.local_transforms)) || i32(selected_node) >= i32(len(scene.world_transforms)) {
		history_cancel_active_edit()
		g_world_gizmo_interacting = false
		if im.get_current_context() != nil {
			im.text_disabled("Select a node to edit its transform")
		} else {
			log.errorf("[draw_selected_node_gizmo_ui] ImGui context is nil, skipping im.text_disabled call!")
		}
		return false
	}


	name := vk.scene_get_node_name(scene, selected_node)
	if len(name) == 0 {
		name = "(unnamed)"
	}

	im.separator()
	im.text("Gizmo")
	im.text("Node: %d", selected_node)
	im.text_disabled("%s", fmt.ctprintf("%s", name))


	@(static) transform_space := Transform_Space.Local
	im.text("Space")
	im.same_line()
	if im.small_button("Local") {
		transform_space = .Local
	}
	im.same_line()
	if im.small_button("World") {
		transform_space = .World
	}


	if transform_space == .Local {
		if i32(selected_node) < 0 || i32(selected_node) >= i32(len(scene.local_transforms)) {
			log.errorf("[draw_selected_node_gizmo_ui] Invalid node index for local transform: %d", selected_node)
			im.text_disabled("Invalid node index for local transform")
			return false
		}
		t := scene.local_transforms[selected_node]
		position, rotation_quat, scale := transform_components_from_local(t)

		changed := false
		commit_edit := false
		changed = im.drag_float3("Translate", &position, 0.05, 0, 0, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit
		changed = im.drag_float4("Rotate (Quat)", &rotation_quat, 0.01, -1, 1, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit
		changed = im.drag_float3("Scale", &scale, 0.05, -1000, 1000, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit

		if changed {
			history_begin_active_edit(scene, selected_node)
			apply_transform_components_to_node(
				scene,
				selected_node,
				.Local,
				position,
				rotation_quat,
				scale,
			)
		}
		history_commit_active_edit_if_requested(scene, commit_edit)
	} else {
		if i32(selected_node) < 0 || i32(selected_node) >= i32(len(scene.world_transforms)) {
			log.errorf("[draw_selected_node_gizmo_ui] Invalid node index for world transform: %d", selected_node)
			im.text_disabled("Invalid node index for world transform")
			return false
		}
		world_t := scene.world_transforms[selected_node]
		position, rotation_quat, scale := transform_components_from_world(world_t)

		changed := false
		commit_edit := false
		changed = im.drag_float3("World Translate", &position, 0.05, 0, 0, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit
		changed = im.drag_float4("World Rotate (Quat)", &rotation_quat, 0.01, -1, 1, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit
		changed = im.drag_float3("World Scale", &scale, 0.05, -1000, 1000, "%.3f") || changed
		commit_edit = im.is_item_deactivated_after_edit() || commit_edit

		if changed {
			history_begin_active_edit(scene, selected_node)
			apply_transform_components_to_node(
				scene,
				selected_node,
				.World,
				position,
				rotation_quat,
				scale,
			)
		}
		history_commit_active_edit_if_requested(scene, commit_edit)
	}


	draw_world_gizmo(scene, selected_node, view, proj)


	im.separator()
	im.text("Material Slots")

	mesh_data_ok := len(scene.mesh_for_node) > 0 && len(scene.meshes) > 0 && len(scene.materials) > 0
	slot_count: int = 0
	if mesh_data_ok && i32(selected_node) >= 0 && i32(selected_node) < i32(len(scene.mesh_for_node)) {
		slot_count = int(vk.scene_get_node_material_slot_count(scene, i32(selected_node)))
	}
	if mesh_data_ok && slot_count > 0 {
		for slot: int = 0; slot < slot_count; slot += 1 {
			material_index: u32
			material_valid := false
			if mat, ok := vk.scene_get_node_slot_effective_material(scene, i32(selected_node), i32(slot));
			   ok && int(mat) >= 0 && int(mat) < int(len(scene.materials)) {
				material_index = mat
				material_valid = true
			}

			slot_name := editor_get_node_material_slot_name(scene, i32(selected_node), i32(slot))
			slot_label := fmt.tprintf("Slot %d", slot)
			if len(slot_name) > 0 {
				slot_label = slot_name
			}
			assigned_text := "(none)"
			if material_valid {
				if int(material_index) < len(scene.materials) {
					color_path := scene.materials[material_index].source.color_path
					if len(color_path) > 0 {
						assigned_text = fmt.tprintf(
							"material_%d (%s)",
							material_index,
							display_asset_name(color_path),
						)
					} else {
						assigned_text = fmt.tprintf("material_%d", material_index)
					}
				} else {
					log.warnf("[draw_selected_node_gizmo_ui] material_index %d out of bounds for materials %d", material_index, len(scene.materials))
				}
			}

			im.push_id_int(i32(slot))
			im.text("%s", fmt.ctprintf("%s", slot_label))
			im.text_disabled("Slot Index: %d", i32(slot))
			if len(slot_name) == 0 {
				im.text_disabled("Slot Name: (unnamed)")
			}
			im.text_disabled("%s", fmt.ctprintf("Assigned Material: %s", assigned_text))

			if im.begin_drag_drop_target() {
				if payload := im.accept_drag_drop_payload(MATERIAL_SLOT_ASSET_PAYLOAD_TYPE);
				   payload != nil {
					drop_now := payload.delivery || im.is_mouse_released(.Left)
					if drop_now {
						dragged := cast(^Dragged_Asset_Payload)payload.data
						if dragged != nil &&
						   assign_slot_material != nil &&
						   is_supported_material_asset_path(dragged.path) {
							_ = assign_slot_material(i32(selected_node), i32(slot), dragged.path)
						}
					}
				}
				im.end_drag_drop_target()
			}

			prefer_atlas := false
			if material_valid {
				if int(material_index) < len(scene.material_source) {
					policy := vk.scene_get_material_policy(scene, material_index)
					prefer_atlas = policy != .Force_Standalone
				} else {
					log.warnf("[draw_selected_node_gizmo_ui] material_index %d out of bounds for material_source %d", material_index, len(scene.material_source))
				}
			}
			if im.checkbox("Atlas Material", &prefer_atlas) {
				if set_slot_material_policy != nil {
					_ = set_slot_material_policy(i32(selected_node), i32(slot), prefer_atlas)
				}
			}

			if material_valid && int(material_index) < len(scene.material_source) {
				source_mode := scene.material_source[material_index]
				if source_mode == .Atlas {
					page: int = -1
					if int(material_index) < len(scene.material_atlas_page) {
						page = int(scene.material_atlas_page[material_index])
					}
					im.text_disabled("Effective: Atlas page %d", page)
				} else {
					im.text_disabled("Effective: Standalone")
				}
			}

			im.separator()
			im.pop_id()
		}
	} else {
		log.warnf("[draw_selected_node_gizmo_ui] No mesh/material data for selected node or slot_count=0")
		im.text_disabled("No mesh/material data for selected node")
	}

	delete_requested := false
	if delete_node != nil {
		if im.button("Delete Selected Node") {
			delete_requested = true
		}
		if !im.is_any_item_active() && im.is_key_pressed(.Delete, false) {
			delete_requested = true
		}
	}

	if delete_requested && delete_node != nil {
		history_cancel_active_edit()
		before_snapshot := scene_snapshot_from_scene(scene)
		selected_before := selected_node
		deleted := delete_node(selected_node)
		if deleted {
			after_snapshot := scene_snapshot_from_scene(scene)
			history_push_scene_edit(
				Scene_Edit_Command {
					before = before_snapshot,
					after = after_snapshot,
					selected_before = selected_before,
					selected_after = -1,
				},
			)
		} else {
			scene_snapshot_delete(&before_snapshot)
		}
		return deleted
	}

	return false
}

@(private = "file")
editor_pick_node_from_world_click :: proc(scene: ^vk.Scene) -> i32 {
	if scene == nil || len(scene.hierarchy) == 0 {
		return -1
	}

	vp := im.get_main_viewport()
	mouse := im.get_mouse_pos()
	if mouse.x < vp.work_pos.x || mouse.y < vp.work_pos.y {
		return -1
	}
	if mouse.x > vp.work_pos.x + vp.work_size.x || mouse.y > vp.work_pos.y + vp.work_size.y {
		return -1
	}

	view_w := max(vp.work_size.x, 1)
	view_h := max(vp.work_size.y, 1)
	nx := ((mouse.x - vp.work_pos.x) / view_w) * 2.0 - 1.0
	ny := 1.0 - ((mouse.y - vp.work_pos.y) / view_h) * 2.0

	fov := math.to_radians_f32(70.0)
	aspect := view_w / view_h
	t := math.tan_f32(fov * 0.5)
	dir := [3]f32{nx * aspect * t, ny * t, -1}
	dir_len_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	if dir_len_sq <= 0 {
		return -1
	}
	dir_inv_len := 1.0 / math.sqrt(dir_len_sq)
	dir.x *= dir_inv_len
	dir.y *= dir_inv_len
	dir.z *= dir_inv_len

	origin := [3]f32{0, 0, 5}
	best_t := f32(1e30)
	best_node := i32(-1)

	for node_idx := 0; node_idx < len(scene.hierarchy); node_idx += 1 {
		mesh_idx := scene.mesh_for_node[node_idx]
		if mesh_idx == vk.NO_MESH || int(mesh_idx) >= len(scene.meshes) {
			continue
		}

		world_t := scene.world_transforms[node_idx]
		center := world_t.position

		radius := f32(0.5)
		mesh := scene.meshes[mesh_idx]
		if mesh.bounds.sphere_radius > 0 {
			s := world_t.scale
			max_s := max(max(math.abs(s.x), math.abs(s.y)), math.abs(s.z))
			radius = max(mesh.bounds.sphere_radius * max_s, 0.05)
		}

		oc := origin - center
		a := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
		b := 2.0 * (oc.x * dir.x + oc.y * dir.y + oc.z * dir.z)
		c := oc.x * oc.x + oc.y * oc.y + oc.z * oc.z - radius * radius
		disc := b * b - 4.0 * a * c
		if disc < 0 {
			continue
		}

		sqrt_disc := math.sqrt(disc)
		t0 := (-b - sqrt_disc) / (2.0 * a)
		t1 := (-b + sqrt_disc) / (2.0 * a)
		t_hit := f32(-1)
		if t0 > 0 {
			t_hit = t0
		} else if t1 > 0 {
			t_hit = t1
		}

		if t_hit > 0 && t_hit < best_t {
			best_t = t_hit
			best_node = i32(node_idx)
		}
	}

	return best_node
}

@(private = "file")
editor_update_world_selection :: proc(scene: ^vk.Scene, selected_node: ^i32) {
	if scene == nil {
		return
	}
	if g_world_gizmo_interacting {
		return
	}
	if !im.is_mouse_clicked(.Left, false) {
		return
	}
	if im.get_io().want_capture_mouse {
		return
	}

	picked := editor_pick_node_from_world_click(scene)
	if picked >= 0 {
		selected_node^ = picked
	}
}

@(private = "file")
draw_hierarchy_content_ui :: proc(scene: ^vk.Scene, selected_node: ^i32) {
	if scene == nil {
		return
	}
	if !selected_node_valid(scene, selected_node^) {
		selected_node^ = -1
	}
	for &hierarchy, i in scene.hierarchy {
		if hierarchy.parent == -1 {
			render_scene_tree_ui(scene, i, selected_node)
		}
	}
}

runtime_find_current_level_index :: proc(cfg: ^Runtime_Game_Config_View) -> i32 {
	if cfg == nil {
		return -1
	}
	for lvl, i in cfg.levels {
		if lvl == cfg.current_level {
			return i32(i)
		}
	}
	return -1
}

editor_draw_ui :: proc(params: Editor_UI_Params) {
		editor_browser_init()
		g_world_gizmo_interacting = false
		editor_handle_history_shortcuts(params.scene, &g.selected_node)

		hierarchy_h := params.display_size.y - BROWSER_PANEL_DEFAULT_HEIGHT - 20
		if hierarchy_h < 120 {
			hierarchy_h = 120
		}

		im.set_next_window_pos({10, 10}, .First_Use_Ever)
		im.set_next_window_size({300, hierarchy_h}, .First_Use_Ever)
		hierarchy_open := im.begin("Hierarchy", nil, {.No_Focus_On_Appearing})
		if hierarchy_open {
			if params.scene == nil {
				log.warnf("[editor_draw_ui] params.scene is nil, skipping scene UI")
			} else {
				draw_hierarchy_content_ui(params.scene, &g.selected_node)
				gizmo_deleted := draw_selected_node_gizmo_ui(
					params.scene,
					g.selected_node,
					params.delete_node,
					params.assign_slot_material,
					params.set_slot_material_policy,
					params.view,
					params.proj,
				)
				if gizmo_deleted {
					g.selected_node = -1
					history_cancel_active_edit()
				}
				im.text_disabled("History: Ctrl+Z undo, Ctrl+Y / Ctrl+Shift+Z redo")

				im.separator()
				im.text("Global Atlas Mode")
				if len(params.scene.atlas_manifest.pages) == 0 && len(params.scene.atlas_manifest.mappings) == 0 {
					log.warnf("[editor_draw_ui] scene.atlas_manifest is empty, skipping atlas UI")
				} else {
					global_atlas_auto := params.scene.atlas_manifest.mode == .Auto
					if im.small_button("Disable") {
						if params.set_global_atlas_mode != nil {
							params.set_global_atlas_mode(.Disable)
						}
					}
					im.same_line()
					if im.small_button("Auto") {
						if params.set_global_atlas_mode != nil {
							params.set_global_atlas_mode(.Auto)
						}
					}
					im.same_line()
					if global_atlas_auto {
						im.text_disabled("Current: Auto")
					} else {
						im.text_disabled("Current: Disable")
					}
					im.text("Atlas pages: %d", len(params.scene.atlas_manifest.pages))
					im.text("Atlas mappings: %d", len(params.scene.atlas_manifest.mappings))
					im.text(
						"Atlas bake page size: %d",
						vk.scene_current_atlas_bake_page_size(params.scene),
					)
					im.text("Atlas max pages: %d", params.scene.atlas_manifest.settings.max_pages)
				}
			}

			im.separator()
			im.text("Level")

			cfg := params.runtime_config
			if cfg == nil {
				log.warnf("[editor_draw_ui] params.runtime_config is nil, skipping level UI")
				im.text("Runtime unavailable")
			} else {
				@(static) selected_level_idx: i32 = -1
				@(static) last_level_action: Level_UI_Action = .None

				if selected_level_idx < 0 || selected_level_idx >= i32(len(cfg.levels)) {
					selected_level_idx = runtime_find_current_level_index(cfg)
				}
				if selected_level_idx < 0 && len(cfg.levels) > 0 {
					selected_level_idx = 0
				}

				if len(cfg.levels) == 0 {
					im.text_disabled("No levels configured")
				} else {
					preview_level := cfg.current_level
					if selected_level_idx >= 0 && selected_level_idx < i32(len(cfg.levels)) {
						preview_level = cfg.levels[selected_level_idx]
					}

					preview_level_c := fmt.ctprintf("%s", preview_level)
					if im.begin_combo("Level File", preview_level_c) {
						for lvl, i in cfg.levels {
							is_selected := i32(i) == selected_level_idx
							lvl_c := fmt.ctprintf("%s", lvl)
							if im.selectable(lvl_c, is_selected) {
								selected_level_idx = i32(i)
							}
							if is_selected {
								im.set_item_default_focus()
							}
						}
						im.end_combo()
					}
				}

				if im.button("Load Level") {
					if params.load_level == nil {
						log.warnf("[editor_draw_ui] params.load_level is nil, cannot load level")
					}
					if selected_level_idx < 0 || selected_level_idx >= i32(len(cfg.levels)) {
						log.warnf("[editor_draw_ui] selected_level_idx out of bounds: %d", selected_level_idx)
					}
					if params.load_level != nil &&
					   selected_level_idx >= 0 &&
					   selected_level_idx < i32(len(cfg.levels)) {
						selected_path := cfg.levels[selected_level_idx]
						if params.load_level(selected_path) {
							last_level_action = .Load_Ok
							history_clear()
							if cfg.current_level != selected_path {
								delete(cfg.current_level)
								cfg.current_level = strings.clone(selected_path)
							}
						} else {
							last_level_action = .Load_Failed
						}
					} else {
						last_level_action = .Load_Failed
					}
				}

				if im.button("Save Level") {
					if params.save_level == nil {
						log.warnf("[editor_draw_ui] params.save_level is nil, cannot save level")
					}
					if params.save_level != nil && params.save_level(cfg.current_level) {
						last_level_action = .Save_Ok
					} else {
						last_level_action = .Save_Failed
					}
				}

				if last_level_action != .None {
					im.separator()
					switch last_level_action {
					case .Load_Ok:
						im.text("Last action: Load Level OK")
					case .Load_Failed:
						im.text("Last action: Load Level FAILED")
					case .Save_Ok:
						im.text("Last action: Save Level OK")
					case .Save_Failed:
						im.text("Last action: Save Level FAILED")
					case .None:
					}
				}
			}
		}
		im.end()

		editor_draw_bottom_panels(params.display_size, 0, params.scene, params.add_mesh_node)

		if params.scene != nil {
			editor_update_world_selection(params.scene, &g.selected_node)
		}
}

@(private = "file")
draw_ui_from_vulkan_hook :: proc(params: vk.Editor_Draw_UI_Params) {
	editor_draw_ui(
		Editor_UI_Params {
			display_size = params.display_size,
			runtime_config = cast(^Runtime_Game_Config_View)params.runtime_config,
			scene = params.scene,
			view = params.view,
			proj = params.proj,
			load_level = params.load_level,
			save_level = params.save_level,
			delete_node = params.delete_node,
			add_mesh_node = params.add_mesh_node,
			set_global_atlas_mode = params.set_global_atlas_mode,
			assign_slot_material = params.assign_slot_material,
			set_slot_material_policy = params.set_slot_material_policy,
		},
	)
}

register_with_vulkan :: proc() {
	vk.set_editor_hooks(draw_ui_from_vulkan_hook, editor_browser_shutdown)
}

@(private = "file")
editor_find_project_root :: proc() -> (root: string, ok: bool) {
	root_markers := [5]string {
		"Editor/Asset_Converter/main.odin",
		"./Editor/Asset_Converter/main.odin",
		"../Editor/Asset_Converter/main.odin",
		"../../Editor/Asset_Converter/main.odin",
		"../../../Editor/Asset_Converter/main.odin",
	}

	for marker in root_markers {
		if os.exists(marker) {
			marker_dir := os.dir(marker)
			editor_dir := os.dir(marker_dir)
			return os.dir(editor_dir), true
		}
	}

	if exe_dir, exe_dir_err := os.get_executable_directory(context.temp_allocator);
	   exe_dir_err == nil {
		exe_markers := [3]string {
			"Editor/Asset_Converter/main.odin",
			"../Editor/Asset_Converter/main.odin",
			"../../Editor/Asset_Converter/main.odin",
		}
		for rel in exe_markers {
			if candidate, join_err := os.join_path([]string{exe_dir, rel}, context.temp_allocator);
			   join_err == nil {
				if os.exists(candidate) {
					asset_converter_dir := os.dir(candidate)
					editor_dir := os.dir(asset_converter_dir)
					return os.dir(editor_dir), true
				}
			}
		}
	}

	return "", false
}

@(private = "file")
editor_build_default_output_path :: proc(input_path: string) -> string {
	base_name := os.stem(input_path)
	if len(base_name) == 0 {
		base_name = "mesh"
	}
	output_name, output_name_err := os.join_filename(base_name, "ymesh", context.temp_allocator)
	if output_name_err != nil {
		return ""
	}
	output_path, output_path_err := os.join_path(
		[]string{os.dir(input_path), output_name},
		context.temp_allocator,
	)
	if output_path_err != nil {
		return ""
	}
	return output_path
}

@(private = "file")
editor_pick_open_mesh_path :: proc(initial_dir: string) -> (path: string, ok: bool) {
	when ODIN_OS == .Windows {
		file_buf := make([]u16, 4096, context.temp_allocator)
		filter_utf16 := win.utf8_to_utf16(
			"Supported Mesh Files\x00*.obj;*.gltf;*.glb;*.fbx;*.dae\x00All Files\x00*.*\x00\x00",
			context.temp_allocator,
		)
		title_w := win.utf8_to_wstring("Select Mesh File", context.temp_allocator)
		initial_dir_w := win.utf8_to_wstring(initial_dir, context.temp_allocator)

		of := win.OPENFILENAMEW {
			lStructSize     = size_of(win.OPENFILENAMEW),
			lpstrFile       = win.wstring(raw_data(file_buf)),
			nMaxFile        = u32(len(file_buf)),
			lpstrTitle      = title_w,
			lpstrFilter     = win.wstring(raw_data(filter_utf16)),
			lpstrInitialDir = initial_dir_w,
			nFilterIndex    = 1,
			Flags           = u32(
				win.OFN_PATHMUSTEXIST | win.OFN_FILEMUSTEXIST | win.OFN_EXPLORER,
			),
		}

		if !bool(win.GetOpenFileNameW(&of)) {
			return "", false
		}

		picked_path, utf8_err := win.wstring_to_utf8(
			win.wstring(raw_data(file_buf)),
			-1,
			context.temp_allocator,
		)
		if utf8_err != nil {
			return "", false
		}
		return picked_path, true
	} else {
		log.warn("Mesh import dialog is only implemented for Windows")
		return "", false
	}
}

@(private = "file")
editor_pick_save_mesh_path :: proc(default_path: string) -> (path: string, ok: bool) {
	when ODIN_OS == .Windows {
		file_buf := make([]u16, 4096, context.temp_allocator)
		default_utf16 := win.utf8_to_utf16(default_path, context.temp_allocator)
		if len(default_utf16) > 0 {
			copy_len := min(len(default_utf16), len(file_buf) - 1)
			copy(file_buf[:copy_len], default_utf16[:copy_len])
			file_buf[copy_len] = 0
		}

		filter_utf16 := win.utf8_to_utf16(
			"Ymir Mesh (*.ymesh)\x00*.ymesh\x00All Files\x00*.*\x00\x00",
			context.temp_allocator,
		)
		title_w := win.utf8_to_wstring("Save Converted Mesh", context.temp_allocator)
		def_ext_w := win.utf8_to_wstring("ymesh", context.temp_allocator)
		initial_dir_w := win.utf8_to_wstring(os.dir(default_path), context.temp_allocator)

		of := win.OPENFILENAMEW {
			lStructSize     = size_of(win.OPENFILENAMEW),
			lpstrFile       = win.wstring(raw_data(file_buf)),
			nMaxFile        = u32(len(file_buf)),
			lpstrTitle      = title_w,
			lpstrFilter     = win.wstring(raw_data(filter_utf16)),
			lpstrInitialDir = initial_dir_w,
			lpstrDefExt     = def_ext_w,
			nFilterIndex    = 1,
			Flags           = u32(
				win.OFN_OVERWRITEPROMPT | win.OFN_PATHMUSTEXIST | win.OFN_EXPLORER,
			),
		}

		if !bool(win.GetSaveFileNameW(&of)) {
			return "", false
		}

		picked_path, utf8_err := win.wstring_to_utf8(
			win.wstring(raw_data(file_buf)),
			-1,
			context.temp_allocator,
		)
		if utf8_err != nil {
			return "", false
		}
		return picked_path, true
	} else {
		log.warn("Mesh save dialog is only implemented for Windows")
		return "", false
	}
}

@(private = "file")
editor_run_asset_converter :: proc(
	input_path: string,
	output_path: string,
	opts: Import_Convert_Options,
) -> bool {
	// Convert Import_Convert_Options to Asset_Converter.Convert_Options locally
	conv_opts := Asset_Converter.Convert_Options {
		lod_count             = u32(math.max(opts.lod_count, 1)),
		generate_meshlets     = opts.generate_meshlets,
		generate_collision    = opts.generate_collision,
		optimize_overdraw     = opts.optimize_overdraw,
		use_strip_cache       = opts.use_strip_cache,
		max_meshlet_vertices  = u32(math.max(opts.max_meshlet_vertices, 16)),
		max_meshlet_triangles = u32(math.max(opts.max_meshlet_triangles, 16)),
	}
	// Call the asset converter directly
	ok := Asset_Converter.public_convert_mesh(input_path, output_path, conv_opts)
	if ok {
		log.infof("Converted '%s' -> '%s'", input_path, output_path)
	} else {
		log.errorf("Asset conversion failed for '%s'", input_path)
	}
	return ok
}

@(private = "file")
editor_pick_save_asset_path :: proc(default_path: string) -> (path: string, ok: bool) {
	when ODIN_OS == .Windows {
		file_buf := make([]u16, 4096, context.temp_allocator)
		default_utf16 := win.utf8_to_utf16(default_path, context.temp_allocator)
		if len(default_utf16) > 0 {
			copy_len := min(len(default_utf16), len(file_buf) - 1)
			copy(file_buf[:copy_len], default_utf16[:copy_len])
			file_buf[copy_len] = 0
		}

		filter_utf16 := win.utf8_to_utf16("All Files\x00*.*\x00\x00", context.temp_allocator)
		title_w := win.utf8_to_wstring("Export Asset As", context.temp_allocator)
		initial_dir_w := win.utf8_to_wstring(os.dir(default_path), context.temp_allocator)

		of := win.OPENFILENAMEW {
			lStructSize     = size_of(win.OPENFILENAMEW),
			lpstrFile       = win.wstring(raw_data(file_buf)),
			nMaxFile        = u32(len(file_buf)),
			lpstrTitle      = title_w,
			lpstrFilter     = win.wstring(raw_data(filter_utf16)),
			lpstrInitialDir = initial_dir_w,
			nFilterIndex    = 1,
			Flags           = u32(
				win.OFN_OVERWRITEPROMPT | win.OFN_PATHMUSTEXIST | win.OFN_EXPLORER,
			),
		}

		if !bool(win.GetSaveFileNameW(&of)) {
			return "", false
		}

		picked_path, utf8_err := win.wstring_to_utf8(
			win.wstring(raw_data(file_buf)),
			-1,
			context.temp_allocator,
		)
		if utf8_err != nil {
			return "", false
		}
		return picked_path, true
	} else {
		log.warn("Asset save dialog is only implemented for Windows")
		return "", false
	}
}

@(private = "file")
editor_export_asset_file :: proc(source_path: string, output_path: string) -> bool {
	data, read_err := os.read_entire_file(source_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("Export failed: could not read '%s': %v", source_path, read_err)
		return false
	}

	if write_err := os.write_entire_file(
		output_path,
		data,
		os.Permissions_Read_All + {.Write_User},
		true,
	); write_err != nil {
		log.errorf("Export failed: could not write '%s': %v", output_path, write_err)
		return false
	}

	return true
}

// editor_draw_bottom_panels is the main entry point.
// Call it from engine_ui_definition (drawing.odin) after im.new_frame, before im.render.
// display_size should be the main viewport's work_size.
// left_reserved_w is the horizontal space reserved for other editor windows (e.g. hierarchy).
editor_draw_bottom_panels :: proc(
	display_size: im.Vec2,
	left_reserved_w: f32 = 0,
	scene: ^vk.Scene = nil,
	add_mesh_node: vk.Editor_Add_Mesh_Node_Proc = nil,
) {
	editor_browser_init()

	// Lazily load file entries when the current directory changes.
	if g.file_entries_dir != g.dir_current {
		reload_file_entries()
	}

	// Both panels are anchored to the bottom-left of the screen.
	// Each panel uses First_Use_Ever defaults, then lets imgui.ini persist
	// user-customized position and size.
	reserved_w := left_reserved_w
	if reserved_w < 0 {
		reserved_w = 0
	}
	total_w := display_size.x - reserved_w
	if total_w < 200 {
		total_w = 200
	}
	dir_w := total_w * 0.30
	asset_x := reserved_w + dir_w + 4
	asset_w := total_w - dir_w - 4

	base_flags: im.Window_Flags = {.No_Focus_On_Appearing, .No_Bring_To_Front_On_Focus}

	// ── Directory Panel ───────────────────────────────────────────────────────
	im.set_next_window_pos({reserved_w, display_size.y}, .First_Use_Ever, {0, 1})
	im.set_next_window_size({dir_w, BROWSER_PANEL_DEFAULT_HEIGHT}, .First_Use_Ever)
	if im.begin("Directory##ymir", nil, base_flags) {
		im.text_disabled("Root: %s", cstring(raw_data(g.dir_root)))
		im.separator()
		if im.begin_child("##dir_tree", {0, 0}, {}, {}) {
			draw_dir_node(g.dir_root, "(root)")
		}
		im.end_child()
	}
	im.end()

	// ── Asset Browser Panel ───────────────────────────────────────────────────
	im.set_next_window_pos({asset_x, display_size.y}, .First_Use_Ever, {0, 1})
	im.set_next_window_size({asset_w, BROWSER_PANEL_DEFAULT_HEIGHT}, .First_Use_Ever)
	if im.begin("Asset Browser##ymir", nil, base_flags) {
		@(static) last_asset_action: Asset_UI_Action = .None
		// On first draw, load persistent options
		@(static) import_opts: Import_Convert_Options
		if !import_options_loaded {
			load_editor_config()
			import_opts = editor_config_persistent.import_options
		}

		// Toolbar
		if im.small_button("Import") {
			input_path, picked_input := editor_pick_open_mesh_path(g.dir_current)
			if picked_input {
				default_output := editor_build_default_output_path(input_path)
				if len(default_output) == 0 {
					default_output = "mesh.ymesh"
				}
				output_path, picked_output := editor_pick_save_mesh_path(default_output)
				if picked_output {
					if editor_run_asset_converter(input_path, output_path, import_opts) {
						output_dir := os.dir(output_path)
						if len(output_dir) > 0 {
							navigate_to(output_dir)
						}
						delete(g.asset_selected)
						g.asset_selected = strings.clone(output_path)
						last_asset_action = .Import_Ok
					} else {
						last_asset_action = .Import_Failed
					}
				}
			}
		}
		im.same_line()
		if im.tree_node("Import Options##converter") {
			im.set_next_item_width(90)
			changed := false
			im.set_next_item_width(90)
			changed = im.input_int("LOD Count", &import_opts.lod_count) || changed
			if import_opts.lod_count < 1 {
				import_opts.lod_count = 1
			}

			changed = im.checkbox("Generate Meshlets", &import_opts.generate_meshlets) || changed
			if import_opts.generate_meshlets {
				im.set_next_item_width(110)
				changed =
					im.input_int("Max Meshlet Vertices", &import_opts.max_meshlet_vertices) ||
					changed
				if import_opts.max_meshlet_vertices < 16 {
					import_opts.max_meshlet_vertices = 16
				}
				im.set_next_item_width(110)
				changed =
					im.input_int("Max Meshlet Triangles", &import_opts.max_meshlet_triangles) ||
					changed
				if import_opts.max_meshlet_triangles < 16 {
					import_opts.max_meshlet_triangles = 16
				}
			}

			changed =
				im.checkbox("Generate Collision Mesh", &import_opts.generate_collision) || changed
			changed = im.checkbox("Optimize Overdraw", &import_opts.optimize_overdraw) || changed
			changed = im.checkbox("Use Strip Cache", &import_opts.use_strip_cache) || changed
			if changed {
				editor_config_persistent.import_options = import_opts
				save_editor_config(editor_config_persistent)
			}
			im.tree_pop()
		}
		im.same_line()
		can_export := len(g.asset_selected) > 0
		im.begin_disabled(!can_export)
		if im.small_button("Export") {
			default_export := g.asset_selected
			if len(default_export) == 0 {
				default_export = "asset.bin"
			}
			export_path, picked_export := editor_pick_save_asset_path(default_export)
			if picked_export {
				if editor_export_asset_file(g.asset_selected, export_path) {
					last_asset_action = .Export_Ok
				} else {
					last_asset_action = .Export_Failed
				}
			}
		}
		im.end_disabled()
		im.same_line()

		selected_is_ymesh :=
			len(g.asset_selected) > 0 &&
			(strings.ends_with(g.asset_selected, ".ymesh") ||
					strings.ends_with(g.asset_selected, ".YMESH"))
		can_add: bool = selected_is_ymesh && add_mesh_node != nil
		im.begin_disabled(!can_add)
		       if im.small_button("Add YMesh") {
			       before_snapshot := scene_snapshot_from_scene(scene)
			       selected_before := g.selected_node
			       parent_node := g.selected_node
			       if !selected_node_valid(scene, parent_node) {
				       parent_node = -1
			       }
			       node_count_before := len(scene.hierarchy)
			       add_ok := add_mesh_node(g.asset_selected, parent_node)
			       node_count_after := len(scene.hierarchy)
			       if add_ok && node_count_after > node_count_before {
				       added_node := i32(node_count_after) - 1
				       after_snapshot := scene_snapshot_from_scene(scene)
				       history_push_scene_edit(
					       Scene_Edit_Command {
						       before = before_snapshot,
						       after = after_snapshot,
						       selected_before = selected_before,
						       selected_after = added_node,
					       },
				       )
				       g.selected_node = added_node
				       last_asset_action = .Add_Ok
			       } else {
				       scene_snapshot_delete(&before_snapshot)
				       last_asset_action = .Add_Failed
			       }
		       }
		im.end_disabled()
		im.same_line()

		im.set_next_item_width(200)
		im.input_text("##ab_search", cstring(&g.search_buf[0]), size_of(g.search_buf))
		im.same_line()
		im.text_disabled("Search")
		if last_asset_action != .None {
			im.same_line()
			switch last_asset_action {
			case .Import_Ok:
				im.text("Imported")
			case .Import_Failed:
				im.text("Import failed")
			case .Export_Ok:
				im.text("Exported")
			case .Export_Failed:
				im.text("Export failed")
			case .Add_Ok:
				im.text("Added")
			case .Add_Failed:
				im.text("Add failed")
			case .None:
			}
		}
		im.separator()

		search := string(cstring(&g.search_buf[0]))

		if im.begin_child("##asset_list", {0, 0}, {}, {}) {
			if g.file_entries == nil {
				im.text_disabled("(directory empty or unreadable)")
			} else {
				for entry in g.file_entries {
					// Filter by search term (case-sensitive).
					if len(search) > 0 && !strings.contains(entry.name, search) {
						continue
					}
					icon := entry.type == .Directory ? "[D] " : "[F] "
					label := fmt.ctprintf("%s%s", icon, entry.name)
					is_sel := entry.fullpath == g.asset_selected

					if im.selectable(label, is_sel, {.Allow_Double_Click}) {
						delete(g.asset_selected)
						g.asset_selected = strings.clone(entry.fullpath)
						// Double-click a folder to navigate into it.
						if entry.type == .Directory && im.is_mouse_double_clicked(.Left) {
							navigate_to(entry.fullpath)
						}
					}

					if entry.type != .Directory {
						payload := Dragged_Asset_Payload {
							path = entry.fullpath,
						}
						if im.begin_drag_drop_source() {
							_ = im.set_drag_drop_payload(
								MATERIAL_SLOT_ASSET_PAYLOAD_TYPE,
								&payload,
								size_of(Dragged_Asset_Payload),
							)
							im.text("Assign material: %s", cstring(raw_data(entry.name)))
							im.end_drag_drop_source()
						}
					}
				}
			}
		}
		im.end_child()
	}
	im.end()
}

package Asset_Converter

import am "../../Engine/asset_manager"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"

IMPORT_MAX_TEXTURE_DIM :: 4096

// MTL_Material_Raw holds all fields parsed directly from a .mtl file.
// This is an internal type; use Material_Asset for the on-disk JSON schema.
MTL_Material_Raw :: struct {
	name:              string,
	albedo_texture:    string,
	metallic_texture:  string,
	roughness_texture: string,
	normal_texture:    string,
	emissive_texture:  string,
	ao_texture:        string,
	specular_texture:  string,
	opacity_texture:   string,
	emissive:          [3]f32,
	metallic:          f32,
	roughness:         f32,
	opacity:           f32,
}

// Material_Asset is the on-disk JSON schema for a single material.
// It is written by the converter and read by the runtime.
Material_Asset :: struct {
	name:             string,
	color_path:       string,
	metal_rough_path: string,
	normal_path:      string,
	emissive_path:    string,
	ao_path:          string,
	alpha_mode:       string,
	emissive_color:   [3]f32,
	metallic_factor:  f32,
	roughness_factor: f32,
	alpha_cutoff:     f32,
}

resolve_texture_source_path :: proc(tex: string, mtl_dir: string) -> string {
	if len(tex) == 0 {
		return ""
	}
	candidate, join_err := os.join_path([]string{mtl_dir, tex}, context.temp_allocator)
	if join_err == nil && os.exists(candidate) {
		return candidate
	}
	if os.exists(tex) {
		return tex
	}
	return ""
}

sample_texture_channel_scaled :: proc(
	tex: am.Loaded_Texture,
	x, y, target_w, target_h: int,
	channel: int,
	default_value: u8,
) -> u8 {
	if tex.pixels == nil || tex.width <= 0 || tex.height <= 0 || target_w <= 0 || target_h <= 0 {
		return default_value
	}
	sx := (x * int(tex.width)) / target_w
	sy := (y * int(tex.height)) / target_h
	if sx < 0 do sx = 0
	if sy < 0 do sy = 0
	if sx >= int(tex.width) do sx = int(tex.width) - 1
	if sy >= int(tex.height) do sy = int(tex.height) - 1
	idx := (sy * int(tex.width) + sx) * 4
	return tex.pixels[idx + channel]
}

write_capped_texture_copy :: proc(
	source_path: string,
	output_dir: string,
	output_stem: string,
	sanitized_name: string,
	kind: string,
	texture_cache: ^map[string]string,
) -> string {
	if len(source_path) == 0 {
		return ""
	}
	cache_key := fmt.aprintf("cap|%s", source_path, allocator = context.temp_allocator)
	if cached, ok := texture_cache^[cache_key]; ok {
		return cached
	}

	tex, load_ok := am.load_texture_from_file(source_path)
	if !load_ok {
		log.warnf("write_capped_texture_copy: failed to load '%s'", source_path)
		return ""
	}
	defer am.free_texture(tex)

	resized_pixels, out_w, out_h := resize_rgba_to_max(
		tex.pixels,
		int(tex.width),
		int(tex.height),
		IMPORT_MAX_TEXTURE_DIM,
		context.temp_allocator,
	)
	if out_w != int(tex.width) || out_h != int(tex.height) {
		log.infof(
			"write_capped_texture_copy: capped '%s' from %dx%d to %dx%d",
			source_path,
			tex.width,
			tex.height,
			out_w,
			out_h,
		)
	}

	out_name := fmt.aprintf(
		"%s.%s.%s.png",
		output_stem,
		sanitized_name,
		kind,
		allocator = context.temp_allocator,
	)
	out_path, join_err := os.join_path([]string{output_dir, out_name}, context.temp_allocator)
	if join_err != nil {
		log.errorf("write_capped_texture_copy: failed to create output path for '%s'", out_name)
		return ""
	}
	if os.exists(out_path) {
		_ = os.remove(out_path)
	}

	if !save_rgba_to_png(out_path, resized_pixels, i32(out_w), i32(out_h)) {
		return ""
	}

	texture_cache^[cache_key] = out_path
	return out_path
}

write_packed_orm_texture :: proc(
	metal_path: string,
	roughness_path: string,
	ao_path: string,
	output_dir: string,
	output_stem: string,
	sanitized_name: string,
	texture_cache: ^map[string]string,
) -> string {
	if len(metal_path) == 0 && len(roughness_path) == 0 && len(ao_path) == 0 {
		return ""
	}
	cache_key := fmt.aprintf(
		"orm|%s|%s|%s",
		metal_path,
		roughness_path,
		ao_path,
		allocator = context.temp_allocator,
	)
	if cached, ok := texture_cache^[cache_key]; ok {
		return cached
	}

	metal_tex: am.Loaded_Texture
	rough_tex: am.Loaded_Texture
	ao_tex: am.Loaded_Texture
	has_metal := false
	has_rough := false
	has_ao := false

	if len(metal_path) > 0 {
		if t, ok := am.load_texture_from_file(metal_path); ok {
			metal_tex = t
			has_metal = true
			defer am.free_texture(metal_tex)
		}
	}
	if len(roughness_path) > 0 {
		if t, ok := am.load_texture_from_file(roughness_path); ok {
			rough_tex = t
			has_rough = true
			defer am.free_texture(rough_tex)
		}
	}
	if len(ao_path) > 0 {
		if t, ok := am.load_texture_from_file(ao_path); ok {
			ao_tex = t
			has_ao = true
			defer am.free_texture(ao_tex)
		}
	}

	if !has_metal && !has_rough && !has_ao {
		return ""
	}

	target_w := 0
	target_h := 0
	if has_rough {
		target_w = int(rough_tex.width)
		target_h = int(rough_tex.height)
	} else if has_metal {
		target_w = int(metal_tex.width)
		target_h = int(metal_tex.height)
	} else {
		target_w = int(ao_tex.width)
		target_h = int(ao_tex.height)
	}
	if target_w <= 0 || target_h <= 0 {
		return ""
	}

	total_size := target_w * target_h * 4
	orm_ptr, alloc_err := mem.alloc(total_size, 8, context.temp_allocator)
	if alloc_err != nil || orm_ptr == nil {
		log.errorf("write_packed_orm_texture: allocation failed for %d bytes", total_size)
		return ""
	}
	orm_pixels := cast([^]u8)orm_ptr

	for y := 0; y < target_h; y += 1 {
		for x := 0; x < target_w; x += 1 {
			idx := (y * target_w + x) * 4
			orm_pixels[idx + 0] = sample_texture_channel_scaled(ao_tex, x, y, target_w, target_h, 0, 255)
			orm_pixels[idx + 1] = sample_texture_channel_scaled(rough_tex, x, y, target_w, target_h, 0, 128)
			orm_pixels[idx + 2] = sample_texture_channel_scaled(metal_tex, x, y, target_w, target_h, 0, 0)
			orm_pixels[idx + 3] = 255
		}
	}

	resized_pixels, out_w, out_h := resize_rgba_to_max(
		orm_pixels,
		target_w,
		target_h,
		IMPORT_MAX_TEXTURE_DIM,
		context.temp_allocator,
	)

	out_name := fmt.aprintf(
		"%s.%s.orm.png",
		output_stem,
		sanitized_name,
		allocator = context.temp_allocator,
	)
	out_path, join_err := os.join_path([]string{output_dir, out_name}, context.temp_allocator)
	if join_err != nil {
		log.errorf("write_packed_orm_texture: failed to create output path for '%s'", out_name)
		return ""
	}
	if os.exists(out_path) {
		_ = os.remove(out_path)
	}
	if !save_rgba_to_png(out_path, resized_pixels, i32(out_w), i32(out_h)) {
		return ""
	}

	texture_cache^[cache_key] = out_path
	return out_path
}

write_material_asset_sidecar :: proc(
	output_path: string,
	mesh_name: string,
	slots: []am.Cooked_Mesh_Material_Slot,
	materials: []MTL_Material_Raw,
	mtl_dir: string,
) -> (
	material_files: []string,
	slot_names: []string,
) {
	log.infof("Writing material sidecar for '%s' (%d slots, %d materials)", mesh_name, len(slots), len(materials))

	output_stem := get_file_name_without_ext(output_path)
	output_dir := os.dir(output_path)

	material_files_local := make([dynamic]string, 0)
	slot_names = make([dynamic]string, len(slots))[:]
	texture_cache := make(map[string]string)
	defer delete(texture_cache)

	for i := 0; i < len(slots); i += 1 {
		slot_names[i] = strings.clone(slots[i].slot_name)
	}

	if len(materials) == 0 {
		log.warnf(
			"[sidecar] No materials found for mesh '%s', writing default material for each slot.",
			mesh_name,
		)
	}

	for i := 0; i < len(slots); i += 1 {
		slot_name_raw := slots[i].slot_name
		slot_name_norm := strings.to_lower(
			strip_wrapping_quotes(strings.trim_space(slot_name_raw)),
			context.temp_allocator,
		)
		mat_idx := -1
		for j := 0; j < len(materials); j += 1 {
			mat_name_norm := strings.to_lower(
				strip_wrapping_quotes(strings.trim_space(materials[j].name)),
				context.temp_allocator,
			)
			if mat_name_norm == slot_name_norm {
				mat_idx = j
				break
			}
		}
		sanitized_name := sanitize_file_component(slot_name_norm)
		if len(sanitized_name) == 0 {
			sanitized_name = fmt.aprintf("material_%d", i, allocator = context.temp_allocator)
		}
		asset_name := fmt.aprintf(
			"%s.%s.ymat.json",
			output_stem,
			sanitized_name,
			allocator = context.temp_allocator,
		)
		asset_path, join_err := os.join_path(
			[]string{output_dir, asset_name},
			context.temp_allocator,
		)
		if join_err != nil {
			log.errorf("Failed to join path for material file: %s", asset_name)
			append(&material_files_local, "")
			continue
		}
		if os.exists(asset_path) {
			os.remove(asset_path)
		}

		if mat_idx >= 0 {
			mat := materials[mat_idx]

			resolved_color_src := resolve_texture_source_path(mat.albedo_texture, mtl_dir)
			resolved_metal_src := resolve_texture_source_path(mat.metallic_texture, mtl_dir)
			resolved_rough_src := resolve_texture_source_path(mat.roughness_texture, mtl_dir)
			resolved_normal_src := resolve_texture_source_path(mat.normal_texture, mtl_dir)
			resolved_emissive_src := resolve_texture_source_path(mat.emissive_texture, mtl_dir)
			resolved_ao_src := resolve_texture_source_path(mat.ao_texture, mtl_dir)

			color_out := write_capped_texture_copy(
				resolved_color_src,
				output_dir,
				output_stem,
				sanitized_name,
				"color",
				&texture_cache,
			)

			metal_rough_out := ""
			if len(resolved_metal_src) > 0 || len(resolved_rough_src) > 0 || len(resolved_ao_src) > 0 {
				metal_rough_out = write_packed_orm_texture(
					resolved_metal_src,
					resolved_rough_src,
					resolved_ao_src,
					output_dir,
					output_stem,
					sanitized_name,
					&texture_cache,
				)
			}
			if len(metal_rough_out) == 0 {
				fallback_mr := resolved_metal_src
				if len(fallback_mr) == 0 {
					fallback_mr = resolved_rough_src
				}
				metal_rough_out = write_capped_texture_copy(
					fallback_mr,
					output_dir,
					output_stem,
					sanitized_name,
					"metal_rough",
					&texture_cache,
				)
			}

			normal_out := write_capped_texture_copy(
				resolved_normal_src,
				output_dir,
				output_stem,
				sanitized_name,
				"normal",
				&texture_cache,
			)
			emissive_out := write_capped_texture_copy(
				resolved_emissive_src,
				output_dir,
				output_stem,
				sanitized_name,
				"emissive",
				&texture_cache,
			)
			ao_out := ""
			if len(metal_rough_out) == 0 {
				ao_out = write_capped_texture_copy(
					resolved_ao_src,
					output_dir,
					output_stem,
					sanitized_name,
					"ao",
					&texture_cache,
				)
			}

			asset := Material_Asset {
				name             = slot_name_norm,
				color_path       = color_out,
				metal_rough_path = metal_rough_out,
				normal_path      = normal_out,
				emissive_path    = emissive_out,
				ao_path          = ao_out,
				emissive_color   = mat.emissive,
				metallic_factor  = mat.metallic,
				roughness_factor = mat.roughness,
				alpha_mode       = "opaque",
				alpha_cutoff     = 0.5,
			}
			if mat.opacity > 0 && mat.opacity < 1.0 {
				asset.alpha_mode = "blend"
			}
			asset_bytes, _ := json.marshal(asset)
			if asset_bytes == nil {
				log.errorf("Failed to marshal material asset for slot '%s'", slot_name_norm)
				append(&material_files_local, "")
				continue
			}
			if os.write_entire_file(asset_path, asset_bytes) == nil {
				append(&material_files_local, strings.clone(asset_path))
			} else {
				log.errorf("Failed to write material file: %s", asset_path)
				append(&material_files_local, "")
			}
			continue
		} else {
			log.warnf("No matching material found for slot '%s' in mesh '%s', writing minimal empty asset.", slot_name_norm, mesh_name)
			asset := Material_Asset {
				name             = slot_name_norm,
				color_path       = "",
				metal_rough_path = "",
				normal_path      = "",
				emissive_path    = "",
				ao_path          = "",
				alpha_mode       = "opaque",
				emissive_color   = {},
				metallic_factor  = 0,
				roughness_factor = 0.5,
				alpha_cutoff     = 0.5,
			}
			asset_bytes, _ := json.marshal(asset)
			if asset_bytes == nil {
				log.errorf("Failed to marshal minimal material asset for slot '%s'", slot_name_norm)
				append(&material_files_local, "")
				continue
			}
			if os.write_entire_file(asset_path, asset_bytes) == nil {
				append(&material_files_local, strings.clone(asset_path))
			} else {
				log.errorf("Failed to write minimal material file: %s", asset_path)
				append(&material_files_local, "")
			}
			continue
		}
	}

	sidecar := Material_Sidecar_File {
		mesh_path      = output_path,
		mesh_name      = mesh_name,
		materials_file = fmt.aprintf(
			"%s.materials.json",
			output_path,
			allocator = context.temp_allocator,
		),
		slot_names     = slot_names[:],
		material_files = material_files_local[:],
	}
	bytes, _ := json.marshal(sidecar)
	if bytes == nil {
		log.errorf("Failed to marshal material sidecar for mesh '%s'", mesh_name)
		return material_files_local[:], slot_names[:]
	}

	sidecar_path := sidecar.materials_file
	if os.write_entire_file(sidecar_path, bytes) == nil {
	} else {
		log.warnf("Failed to write material sidecar '%s'", sidecar_path)
	}
	return material_files_local[:], slot_names[:]
}

// Parses a .mtl file and returns a list of material definitions with PBR support.
parse_mtl_file :: proc(path: string) -> []MTL_Material_Raw {
	// NOTE: Caller is responsible for deleting the returned materials array after use.
	materials: [dynamic]MTL_Material_Raw
	current: ^MTL_Material_Raw = nil
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintf("Failed to read MTL file: %s\n", path)
		return materials[:]
	}
	defer delete(data, context.temp_allocator)
	content := string(data)
	// Skip UTF-8 BOM if present
	if len(content) >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF {
		content = content[3:]
	}
	// Remove any leading non-printable characters (defensive)
	for len(content) > 0 && (content[0] < 32 || content[0] > 126) {
		content = content[1:]
	}
	lines := strings.split(content, "\n", context.temp_allocator)
	for line in lines {
		line_trim := strings.trim_space(line)
		if len(line_trim) == 0 || line_trim[0] == '#' {
			continue
		}
		if strings.has_prefix(line_trim, "newmtl ") {
			mat_name := strings.to_lower(
				strip_wrapping_quotes(strings.trim_space(line_trim[7:])),
				context.temp_allocator,
			)
			// Defensive: skip non-ASCII material names and warn
			is_ascii := true
			for c in mat_name {
				if c < 32 || c > 126 {
					is_ascii = false
					break
				}
			}
			if !is_ascii {
				fmt.eprintf(
					"[WARN] Skipping non-ASCII material name in %s: '%s'\n",
					path,
					mat_name,
				)
				continue
			}
			mat := MTL_Material_Raw {
				name = mat_name,
			}
			append(&materials, mat)
			current = &materials[len(materials) - 1]
			continue
		}
		// Only parse property lines if we are inside a material definition
		if current == nil {
			continue
		}
		if strings.has_prefix(line_trim, "map_Kd ") {
			current.albedo_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "map_Ks ") {
			current.specular_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "map_Bump ") ||
		   strings.has_prefix(line_trim, "bump ") {
			// Support both map_Bump and bump
			idx := 9 if strings.has_prefix(line_trim, "map_Bump ") else 5
			current.normal_texture = strings.trim_space(line_trim[idx:])
		} else if strings.has_prefix(line_trim, "map_Ke ") {
			current.emissive_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "map_d ") {
			current.opacity_texture = strings.trim_space(line_trim[6:])
		} else if strings.has_prefix(line_trim, "map_Pm ") {
			current.metallic_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "map_Pr ") {
			current.roughness_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "map_AO ") {
			current.ao_texture = strings.trim_space(line_trim[7:])
		} else if strings.has_prefix(line_trim, "Ns ") {
			// Specular exponent (not directly PBR, but sometimes mapped)
			// skip for now
		} else if strings.has_prefix(line_trim, "Pm ") {
			// Metallic scalar
			val := strings.trim_space(line_trim[3:])
			metallic_val, _ := strconv.parse_f64(val)
			current.metallic = f32(metallic_val)
		} else if strings.has_prefix(line_trim, "Pr ") {
			// Roughness scalar
			val := strings.trim_space(line_trim[3:])
			roughness_val, _ := strconv.parse_f64(val)
			current.roughness = f32(roughness_val)
		} else if strings.has_prefix(line_trim, "Ke ") {
			// Emissive color
			vals := strings.split(strings.trim_space(line_trim[3:]), " ", context.temp_allocator)
			if len(vals) >= 3 {
				e0, _ := strconv.parse_f64(vals[0])
				e1, _ := strconv.parse_f64(vals[1])
				e2, _ := strconv.parse_f64(vals[2])
				current.emissive[0] = f32(e0)
				current.emissive[1] = f32(e1)
				current.emissive[2] = f32(e2)
			}
		} else if strings.has_prefix(line_trim, "d ") {
			// Opacity scalar
			val := strings.trim_space(line_trim[2:])
			opacity_val, _ := strconv.parse_f64(val)
			current.opacity = f32(opacity_val)
		}
	}
	return materials[:]
}

save_rgba_to_png :: proc(path: string, pixels: [^]u8, width, height: i32) -> bool {
	// stbi.write_png expects: (filename: cstring, w: i32, h: i32, comp: i32, data: rawptr, stride_in_bytes: i32)
	stride := width * 4
	// Allocate null-terminated buffer for cstring
	path_buf := make([dynamic]u8, len(path) + 1)
	defer delete(path_buf)
	for i in 0 ..< len(path) {
		path_buf[i] = path[i]
	}
	path_buf[len(path)] = 0
	cpath := cast(cstring)raw_data(path_buf)
	size := width * height * 4
	ok := stbi.write_png(cpath, i32(width), i32(height), 4, raw_data(pixels[:size]), i32(stride))
	if ok == 0 {
		log.errorf("PNG save failed: %v", path)
		return false
	}
	return true
}

save_rgba_to_jpeg :: proc(path: string, pixels: [^]u8, width, height: i32, quality: int) -> bool {
	// stbi.write_jpg expects: (filename: cstring, w: i32, h: i32, comp: i32, data: rawptr, quality: i32)
	// Allocate null-terminated buffer for cstring
	path_buf := make([dynamic]u8, len(path) + 1)
	for i in 0 ..< len(path) {
		path_buf[i] = path[i]
	}
	path_buf[len(path)] = 0
	cpath := cast(cstring)raw_data(path_buf)
	size := width * height * 4
	ok := stbi.write_jpg(cpath, i32(width), i32(height), 4, raw_data(pixels[:size]), i32(quality))
	if ok == 0 {
		log.errorf("JPEG save failed: %v", path)
		return false
	}
	return true
}

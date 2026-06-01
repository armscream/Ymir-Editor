package Asset_Converter

import "core:log"
import "core:mem"
import "core:slice"

resize_rgba_to_max :: proc(
	src: [^]u8,
	width, height, max_dim: int,
	allocator: mem.Allocator,
) -> (
	dst: [^]u8,
	out_w: int,
	out_h: int,
) {
	is_pow2 :: proc(x: int) -> bool {return x > 0 && (x & (x - 1)) == 0}
	if width <= max_dim && height <= max_dim {
		return src, width, height
	}
	if is_pow2(width) && is_pow2(height) && (width > max_dim || height > max_dim) {
		out_w = width / 2
		out_h = height / 2
		alloc_size := out_w * 4
		total_size := out_w * out_h * 4
		ptr, _ := mem.alloc(total_size, 8, allocator)
		if ptr == nil {
			log.errorf(
				"resize_rgba_to_max: Failed to allocate %d bytes for %dx%d RGBA downscale",
				total_size,
				out_w,
				out_h,
			)
			return src, width, height
		}
		dst = ([^]u8)(ptr)
		row_ptr, _ := mem.alloc(alloc_size, 8, allocator)
		if row_ptr == nil {
			log.errorf("resize_rgba_to_max: Failed to allocate row buffer for streaming downscale")
			return src, width, height
		}
		row_buf := slice.bytes_from_ptr(row_ptr, alloc_size)
		for y := 0; y < out_h; y += 1 {
			for x := 0; x < out_w; x += 1 {
				src_x := x * 2
				src_y := y * 2
				src_idx := (src_y * width + src_x) * 4
				r, g, b, a := 0, 0, 0, 0
				for dy in 0 ..= 1 {
					for dx in 0 ..= 1 {
						px_idx := src_idx + ((dy * width + dx) * 4)
						r += int(src[px_idx + 0])
						g += int(src[px_idx + 1])
						b += int(src[px_idx + 2])
						a += int(src[px_idx + 3])
					}
				}
				row_buf[x * 4 + 0] = u8(r / 4)
				row_buf[x * 4 + 1] = u8(g / 4)
				row_buf[x * 4 + 2] = u8(b / 4)
				row_buf[x * 4 + 3] = u8(a / 4)
			}
			dst_off := y * out_w * 4
			// Copy row_buf into the correct offset in dst
			for i := 0; i < alloc_size; i += 1 {
				dst[dst_off + i] = row_buf[i]
			}
		}
			   // (no free needed for temp/arena allocator)
		return dst, out_w, out_h
	}
	return src, width, height
}

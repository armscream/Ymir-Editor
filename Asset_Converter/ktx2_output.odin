package Asset_Converter

import ktx "../../Engine/Libs/ktx"
import "core:c"
import libc "core:c/libc"
import "core:log"
import "core:strings"

// save_rgba_to_ktx2: Save RGBA8 pixel data to a KTX2 file using libktx
save_rgba_to_ktx2 :: proc(file_path: string, pixels: ^u8, width: i32, height: i32) -> bool {
	info := ktx.ktxTexture2_CreateInfo {
		baseWidth        = u32(width),
		baseHeight       = u32(height),
		baseDepth        = 1,
		numDimensions    = 2,
		numLevels        = 1,
		numLayers        = 1,
		numFaces         = 1,
		isArray          = 0,
		generateMipmaps  = 0,
		glInternalformat = 0x8058, // GL_RGBA8
		vkFormat         = 37, // VK_FORMAT_R8G8B8A8_UNORM
	}
	tex: ^ktx.ktxTexture2
	err := ktx.ktxTexture2_Create(&info, 0, &tex)
	if err != ktx.KTX_SUCCESS || tex == nil {
		log.errorf("ktxTexture2_Create failed: %d", err)
		return false
	}
	defer ktx.ktxTexture2_Destroy(tex)
	size := c.size_t(width * height * 4)
	err = ktx.ktxTexture2_SetImageFromMemory(tex, 0, 0, 0, pixels, size)
	if err != ktx.KTX_SUCCESS {
		log.errorf("ktxTexture_SetImageFromMemory failed: %d", err)
		return false
	}
	cpath, cstr_err := strings.clone_to_cstring(file_path)
	if cstr_err != nil {
		log.errorf("Failed to convert path to cstring: %v", cstr_err)
		return false
	}
	defer libc.free(rawptr(cpath))
	err = ktx.ktxTexture2_WriteToNamedFile(tex, cpath)
	if err != ktx.KTX_SUCCESS {
		log.errorf("ktxTexture2_WriteToNamedFile failed: %d", err)
		return false
	}
	return true
}

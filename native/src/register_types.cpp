#include "register_types.h"

#include "native_bullet_sim.h"

#include <godot_cpp/godot.hpp>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

using namespace godot;

// After CORE deinitialize, Godot dlcloses this GDExtension. godot-cpp has
// already created function-local static StringNames in GDCLASS::get_class_static()
// (first called from GDREGISTER_CLASS). Their destructors are registered with
// the C++ runtime and can run after the .so has been unmapped, or can call
// into the engine after its StringName / variant tables are gone. Local
// evidence: --quit SIGSEGV with RIP in a ~1.4 MiB hole the size of this
// library, which is missing from /proc/maps; lua-gdextension is still mapped;
// rbp is 0 so there is no usable unwind. We have no static Godot types of our
// own to clear in uninitialize_scriptshot_native, so we pin the module until
// process exit (late calls land on mapped memory) and SConstruct patches
// godot-cpp so those destructors do not call into a deinitialized engine.
static void pin_library() {
#ifdef _WIN32
	HMODULE module = nullptr;
	GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
			reinterpret_cast<LPCWSTR>(reinterpret_cast<const void *>(&pin_library)), &module);
#else
	Dl_info info;
	if (dladdr(reinterpret_cast<const void *>(&pin_library), &info) && info.dli_fname != nullptr) {
		(void)dlopen(info.dli_fname, RTLD_NOW | RTLD_NODELETE);
	}
#endif
}

void initialize_scriptshot_native(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	pin_library();
	GDREGISTER_CLASS(scriptshot::NativeBulletSim);
}

void uninitialize_scriptshot_native(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT scriptshot_native_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_scriptshot_native);
	init_obj.register_terminator(uninitialize_scriptshot_native);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}

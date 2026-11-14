#include "crash_locator.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#ifdef _WIN32
#include <windows.h>
#else
#include <execinfo.h>
#include <csignal>
#include <unistd.h>
#endif

namespace {

bool locator_requested() {
	const char *value = std::getenv("SCRIPTSHOT_CRASH_LOCATOR");
	return value != nullptr && value[0] == '1' && value[1] == '\0';
}

#ifdef _WIN32

void print_module_offset(const void *addr, const char *label) {
	HMODULE module = nullptr;
	if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
				reinterpret_cast<LPCSTR>(addr), &module)
			|| module == nullptr) {
		std::fprintf(stderr, "scriptshot crash locator: %s %p (module unknown)\n", label, addr);
		return;
	}
	char name[MAX_PATH] = {};
	if (GetModuleFileNameA(module, name, MAX_PATH) == 0) {
		name[0] = '?';
		name[1] = '\0';
	}
	const char *base = name;
	for (const char *p = name; *p; ++p) {
		if (*p == '\\' || *p == '/') {
			base = p + 1;
		}
	}
	const unsigned long long rva = static_cast<unsigned long long>(
			reinterpret_cast<uintptr_t>(addr) - reinterpret_cast<uintptr_t>(module));
	std::fprintf(stderr, "scriptshot crash locator: %s %s+0x%llx\n", label, base, rva);
}

LONG CALLBACK scriptshot_vectored_handler(EXCEPTION_POINTERS *info) {
	if (info == nullptr || info->ExceptionRecord == nullptr) {
		return EXCEPTION_CONTINUE_SEARCH;
	}
	if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) {
		return EXCEPTION_CONTINUE_SEARCH;
	}
	print_module_offset(info->ExceptionRecord->ExceptionAddress, "fault");
	void *frames[8] = {};
	const USHORT n = RtlCaptureStackBackTrace(0, 8, frames, nullptr);
	for (USHORT i = 0; i < n; ++i) {
		print_module_offset(frames[i], "ret");
	}
	std::fflush(stderr);
	return EXCEPTION_CONTINUE_SEARCH;
}

#else

void scriptshot_sigsegv_handler(int sig) {
	std::fprintf(stderr, "scriptshot crash locator: signal %d\n", sig);
	std::fflush(stderr);
	void *frames[16] = {};
	const int n = backtrace(frames, 16);
	backtrace_symbols_fd(frames, n, STDERR_FILENO);
	std::fflush(stderr);
	std::signal(sig, SIG_DFL);
	std::raise(sig);
}

#endif

} // namespace

void scriptshot_install_crash_locator() {
	if (!locator_requested()) {
		return;
	}
#ifdef _WIN32
	if (AddVectoredExceptionHandler(1, scriptshot_vectored_handler) == nullptr) {
		std::fprintf(stderr, "scriptshot crash locator: AddVectoredExceptionHandler failed\n");
		std::fflush(stderr);
		return;
	}
#else
	if (std::signal(SIGSEGV, scriptshot_sigsegv_handler) == SIG_ERR) {
		std::fprintf(stderr, "scriptshot crash locator: signal(SIGSEGV) failed\n");
		std::fflush(stderr);
		return;
	}
#endif
	std::fprintf(stderr, "scriptshot crash locator: enabled\n");
	std::fflush(stderr);
}

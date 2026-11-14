#include "crash_locator.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__EMSCRIPTEN__)
// No process-signal backtrace on web.
#elif defined(__has_include) && __has_include(<execinfo.h>)
#define SCRIPTSHOT_CRASH_LOCATOR_POSIX 1
#include <csignal>
#include <signal.h>
#include <execinfo.h>
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

#elif defined(SCRIPTSHOT_CRASH_LOCATOR_POSIX)

struct sigaction previous_segv;

void scriptshot_sigsegv_handler(int sig, siginfo_t *info, void *ucontext) {
	std::fprintf(stderr, "scriptshot crash locator: signal %d\n", sig);
	std::fflush(stderr);
	void *frames[16] = {};
	const int n = backtrace(frames, 16);
	backtrace_symbols_fd(frames, n, STDERR_FILENO);
	std::fflush(stderr);
	if (previous_segv.sa_flags & SA_SIGINFO) {
		if (previous_segv.sa_sigaction != nullptr) {
			previous_segv.sa_sigaction(sig, info, ucontext);
		}
	} else if (previous_segv.sa_handler == SIG_DFL || previous_segv.sa_handler == SIG_ERR) {
		previous_segv.sa_handler = SIG_DFL;
		sigaction(sig, &previous_segv, nullptr);
		raise(sig);
	} else if (previous_segv.sa_handler != SIG_IGN && previous_segv.sa_handler != nullptr) {
		previous_segv.sa_handler(sig);
	}
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
#elif defined(SCRIPTSHOT_CRASH_LOCATOR_POSIX)
	struct sigaction sa = {};
	sa.sa_sigaction = scriptshot_sigsegv_handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	if (sigaction(SIGSEGV, &sa, &previous_segv) != 0) {
		std::fprintf(stderr, "scriptshot crash locator: sigaction(SIGSEGV) failed\n");
		std::fflush(stderr);
		return;
	}
#else
	std::fprintf(stderr, "scriptshot crash locator: not supported on this platform\n");
	std::fflush(stderr);
	return;
#endif
	std::fprintf(stderr, "scriptshot crash locator: enabled\n");
	std::fflush(stderr);
}

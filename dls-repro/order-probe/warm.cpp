// Reuse the exact archive's fixture, inputs and byte-exact reference checker.
#define main archived_checker_main
#include "check.cpp"
#undef main
#include <algorithm>
#include <cstdint>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#else
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

using Fixtures = std::vector<std::unique_ptr<Fixture>>;
using Clock = std::chrono::steady_clock;

// Both targets must be reached through the same benchmark call site.
#if defined(_MSC_VER)
__declspec(noinline)
#elif defined(__clang__)
__attribute__((noinline))
#else
__attribute__((noipa))
#endif
void sweeps(Fill fn, Fixtures& fixtures, unsigned n) {
    for (unsigned i = 0; i < n; ++i)
        for (auto& f : fixtures) fn(f->matrix, f->a, f->b, f->c, f->u);
}

static Fill target(char v) { return v == 'A' ? dls_seed_original : dls_seed_cached; }
static bool valid(const Fixtures& fs) {
    return std::all_of(fs.begin(), fs.end(), [](const auto& f) { return f->valid(); });
}
struct Usage { long long cpu_ns, peak_bytes; };
static bool usage(Usage& u) {
#ifdef _WIN32
    FILETIME created, stopped, kernel, user;
    PROCESS_MEMORY_COUNTERS mem{};
    if (!GetProcessTimes(GetCurrentProcess(), &created, &stopped, &kernel, &user) ||
        !K32GetProcessMemoryInfo(GetCurrentProcess(), &mem, sizeof(mem))) return false;
    auto ticks = [](FILETIME t) { return (static_cast<long long>(t.dwHighDateTime) << 32) + t.dwLowDateTime; };
    u = {(ticks(kernel) + ticks(user)) * 100, static_cast<long long>(mem.PeakWorkingSetSize)};
#else
    struct rusage r{};
    if (getrusage(RUSAGE_SELF, &r)) return false;
    auto ns = [](timeval t) { return static_cast<long long>(t.tv_sec)*1000000000 + t.tv_usec*1000; };
    u = {ns(r.ru_utime) + ns(r.ru_stime), static_cast<long long>(r.ru_maxrss)*1024};
#endif
    return true;
}
struct Sample { char v; long long ns; unsigned cpu_before, cpu_after; long long cpu_ns, peak_bytes; };

static unsigned cpu_number() {
#ifdef _WIN32
    return GetCurrentProcessorNumber();
#else
    return static_cast<unsigned>(sched_getcpu());
#endif
}

// Pin before allocating the common fixtures. Never change machine-wide affinity.
static int pin(int requested) {
#ifdef _WIN32
    DWORD_PTR mask, system;
    if (!GetProcessAffinityMask(GetCurrentProcess(), &mask, &system)) return -1;
    const int limit = sizeof(mask) * 8;
    auto allowed = [mask](int i) { return (mask & (DWORD_PTR(1) << i)) != 0; };
#else
    cpu_set_t mask;
    if (sched_getaffinity(0, sizeof(mask), &mask)) return -1;
    const int limit = CPU_SETSIZE;
    auto allowed = [&mask](int i) { return CPU_ISSET(i, &mask); };
#endif
    if (requested == -1) {
        for (int i = 1; i < limit; ++i) if (allowed(i)) { requested = i; break; }
        if (requested == -1) requested = 0;
    }
    if (requested < 0 || requested >= limit || !allowed(requested)) return -1;
#ifdef _WIN32
    if (!SetProcessAffinityMask(GetCurrentProcess(), DWORD_PTR(1) << requested)) return -1;
#else
    CPU_ZERO(&mask);
    CPU_SET(requested, &mask);
    if (sched_setaffinity(0, sizeof(mask), &mask)) return -1;
#endif
    return requested;
}

int main(int argc, char** argv) {
    const bool matrix = argc == 4;
    if (!matrix && argc != 2) return 2;
    const auto count = std::strlen(argv[1]);
    if ((!matrix && count != 32) || !count || count > 512 || std::strspn(argv[1], "AB") != count) return 2;
    unsigned timed_sweeps = 500;
    int cpu = -1;
    if (matrix) {
        char* end;
        long n = std::strtol(argv[2], &end, 10);
        if (!*argv[2] || *end || n < 1 || n > 10000) return 2;
        timed_sweeps = static_cast<unsigned>(n);
        long requested = std::strtol(argv[3], &end, 10);
        if (!*argv[3] || *end || requested < -1 || requested > 1023) return 2;
        cpu = pin(static_cast<int>(requested));
        if (cpu < 0) { std::fputs("Requested logical CPU unavailable\n", stderr); return 5; }
    }
    Fixtures fs;
    for (unsigned test = 0; test < cases; ++test)
        for (unsigned stride : {120u, 127u}) fs.emplace_back(new Fixture(test, stride));
    for (char v : {'A', 'B'}) {
        for (auto& f : fs) {
            auto empty = make_buffer(f->stride);
            std::copy(empty.begin(), empty.end(), f->actual.begin());
        }
        sweeps(target(v), fs, 1);
        if (!valid(fs)) return 3;
    }
    const auto until = Clock::now() + std::chrono::seconds(1);
    do {
        sweeps(target('A'), fs, 16);
        sweeps(target('B'), fs, 16);
    } while (Clock::now() < until);
    std::vector<Sample> samples;
    samples.reserve(count);
    for (const char* p = argv[1]; *p; ++p) {
        Fill fn = target(*p);
        sweeps(fn, fs, 16); // Equal, target-specific conditioning outside every timed slot.
        const unsigned cpu_before = cpu_number();
        Usage before{}, after{};
        if (matrix && !usage(before)) return 6;
        const auto start = Clock::now();
        sweeps(fn, fs, timed_sweeps);
        const auto stop = Clock::now();
        const unsigned cpu_after = cpu_number();
        if (matrix && !usage(after)) return 6;
        if (!valid(fs) || (matrix && (cpu_before != static_cast<unsigned>(cpu) || cpu_before != cpu_after))) return 4;
        samples.push_back({*p, std::chrono::duration_cast<std::chrono::nanoseconds>(stop-start).count(),
                           cpu_before, cpu_after, after.cpu_ns - before.cpu_ns, after.peak_bytes});
    }
    if (matrix) {
#ifdef _WIN32
        const auto pid = GetCurrentProcessId();
#else
        const auto pid = getpid();
#endif
        std::printf("PASS %lu %d %zu %s\n", static_cast<unsigned long>(pid), cpu, fs.size(),
                    reinterpret_cast<std::uintptr_t>(dls_seed_original) <
                    reinterpret_cast<std::uintptr_t>(dls_seed_cached) ? "AB" : "BA");
    }
    for (const auto& s : samples) {
        std::printf("%c %lld %u %u", s.v, s.ns, s.cpu_before, s.cpu_after);
        if (matrix) std::printf(" %lld %lld", s.cpu_ns, s.peak_bytes);
        std::putchar('\n');
    }
    return 0;
}

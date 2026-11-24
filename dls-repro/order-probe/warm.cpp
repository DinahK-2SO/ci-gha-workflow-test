// Reuse the exact archive's fixture, inputs and byte-exact reference checker.
#define main archived_checker_main
#include "check.cpp"
#undef main
#include <algorithm>
#include <windows.h>

using Fixtures = std::vector<std::unique_ptr<Fixture>>;
using Clock = std::chrono::steady_clock;

// Both targets must be reached through the same benchmark call site.
__attribute__((noipa)) void sweeps(Fill fn, Fixtures& fixtures, unsigned n) {
    for (unsigned i = 0; i < n; ++i)
        for (auto& f : fixtures) fn(f->matrix, f->a, f->b, f->c, f->u);
}

static Fill target(char v) { return v == 'A' ? dls_seed_original : dls_seed_cached; }
static bool valid(const Fixtures& fs) {
    return std::all_of(fs.begin(), fs.end(), [](const auto& f) { return f->valid(); });
}
struct Sample { char v; long long ns; unsigned cpu_before, cpu_after; };

int main(int argc, char** argv) {
    if (argc != 2 || std::strlen(argv[1]) != 32 || std::strspn(argv[1], "AB") != 32) return 2;
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
    samples.reserve(32);
    for (const char* p = argv[1]; *p; ++p) {
        Fill fn = target(*p);
        sweeps(fn, fs, 16); // Equal, target-specific conditioning outside every timed slot.
        const unsigned cpu_before = GetCurrentProcessorNumber();
        const auto start = Clock::now();
        sweeps(fn, fs, 500);
        const auto stop = Clock::now();
        const unsigned cpu_after = GetCurrentProcessorNumber();
        if (!valid(fs)) return 4;
        samples.push_back({*p, std::chrono::duration_cast<std::chrono::nanoseconds>(stop-start).count(),
                           cpu_before, cpu_after});
    }
    for (const auto& s : samples)
        std::printf("%c %lld %u %u\n", s.v, s.ns, s.cpu_before, s.cpu_after);
}

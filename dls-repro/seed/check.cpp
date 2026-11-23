#include "dls_seed.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

namespace {
constexpr unsigned rows = 120;
constexpr unsigned columns = 120;
constexpr unsigned guard = 8;
constexpr unsigned cases = 20;

struct Entry {
    unsigned row, column, input, index;
};

const Entry entries[] = {
#include "expected_entries.inc"
};
static_assert(sizeof(entries) / sizeof(entries[0]) == 1968, "Unexpected reference size.");

struct Inputs {
    double values[4][21];
};

Inputs make_inputs(unsigned test) {
    Inputs input{};
    const double extremes[] = {
        (std::numeric_limits<double>::max)(), -(std::numeric_limits<double>::max)(),
        (std::numeric_limits<double>::min)(), -(std::numeric_limits<double>::min)(),
        std::numeric_limits<double>::denorm_min(), -std::numeric_limits<double>::denorm_min(),
        0.0, -0.0
    };
    for (unsigned vector = 0; vector < 4; ++vector) {
        for (unsigned index = 0; index < 21; ++index) {
            double value = 0;
            if (test < 16) {
                const int seed = static_cast<int>(test), i = static_cast<int>(index);
                const double original[] = {
                    static_cast<double>(seed * 31 + i), static_cast<double>(seed * 17 - i * 3),
                    static_cast<double>(seed * 11 + i * 7), static_cast<double>(seed * 5 - i)
                };
                value = original[vector];
            } else if (test == 16) {
                value = (static_cast<int>(index) - 10) * (vector % 2 ? -0.125 : 0.1);
            } else if (test == 17) {
                value = extremes[(index + vector) % 8];
            } else if (test == 18) {
                value = (index + vector) % 2 ? -0.0 : 0.0;
            } else {
                value = (static_cast<int>((index * 37 + vector * 11) % 199) - 99) / 32.0;
            }
            input.values[vector][index] = value;
        }
    }
    return input;
}

std::vector<double> make_buffer(unsigned stride) {
    std::vector<double> buffer(rows * stride + 2 * guard, -987654.125);
    for (unsigned row = 0; row < rows; ++row)
        for (unsigned col = 0; col < columns; ++col)
            buffer[guard + row * stride + col] = 0.0;
    return buffer;
}

using Fill = void (*)(DlsMatrixView&, const DlsValues&, const DlsValues&,
                      const DlsValues&, const DlsValues&);

struct Fixture {
    const unsigned test, stride;
    Inputs input;
    const Inputs before;
    const DlsValues a, b, c, u;
    std::vector<double> actual, expected;
    DlsMatrixView matrix;
    const DlsMatrixView original_view;

    Fixture(unsigned test_, unsigned stride_)
        : test(test_), stride(stride_), input(make_inputs(test)), before(input),
          a{input.values[0]}, b{input.values[1]}, c{input.values[2]}, u{input.values[3]},
          actual(make_buffer(stride)), expected(make_buffer(stride)),
          matrix{reinterpret_cast<unsigned char*>(actual.data() + guard), stride * sizeof(double)},
          original_view(matrix) {
        for (const Entry& entry : entries)
            expected[guard + entry.row * stride + entry.column] = input.values[entry.input][entry.index];
    }
    Fixture(const Fixture&) = delete;
    bool valid() const {
        return matrix.data == original_view.data && matrix.stride_bytes == original_view.stride_bytes &&
               std::memcmp(input.values, before.values, sizeof(input.values)) == 0 &&
               std::memcmp(actual.data(), expected.data(), actual.size() * sizeof(double)) == 0;
    }
};
}

int main(int argc, char** argv) {
    if (argc != 3 || (std::strcmp(argv[1], "original") && std::strcmp(argv[1], "cached")))
        return 2;
    char* end = nullptr;
    const long sweeps = std::strtol(argv[2], &end, 10);
    if (!*argv[2] || *end || sweeps < 1 || sweeps > 100000) return 2;
    Fill fill = std::strcmp(argv[1], "original") == 0 ? dls_seed_original : dls_seed_cached;
    std::vector<std::unique_ptr<Fixture>> fixtures;
    for (unsigned test = 0; test < cases; ++test)
        for (unsigned stride : {120u, 127u})
            fixtures.emplace_back(new Fixture(test, stride));
    const auto sweep = [&]() {
        for (auto& f : fixtures) fill(f->matrix, f->a, f->b, f->c, f->u);
    };
    const auto verify = [&]() {
        for (auto& f : fixtures) if (!f->valid()) {
            std::fprintf(stderr, "Mismatch: case=%u stride=%u variant=%s\n", f->test, f->stride, argv[1]);
            return false;
        }
        return true;
    };
    sweep(); // Pre-touch the same fixtures and verify the first write from a clean matrix.
    if (!verify()) return 1;
    const auto start = std::chrono::steady_clock::now();
    for (long i = 0; i < sweeps; ++i) sweep();
    const auto stopped = std::chrono::steady_clock::now();
    if (!verify()) return 1;
    const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(stopped - start).count();
    std::printf("PASS %s %ld %zu %lld\n", argv[1], sweeps, fixtures.size(), static_cast<long long>(ns));
    return 0;
}

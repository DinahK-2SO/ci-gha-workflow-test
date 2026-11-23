#ifndef DLS_STANDALONE_SEED_HPP
#define DLS_STANDALONE_SEED_HPP

static_assert(sizeof(double) == 8, "The seed expects 64-bit double storage.");
static_assert(sizeof(unsigned long long) == 8, "The seed expects a 64-bit stride.");

struct DlsMatrixView {
    unsigned char* data;
    unsigned long long stride_bytes;

    template <class T> T& at(unsigned row, unsigned col) const {
        return reinterpret_cast<T*>(data + row * stride_bytes)[col];
    }

    template <class T> T* ptr() const {
        return reinterpret_cast<T*>(data);
    }

    unsigned long long step1() const {
        return stride_bytes / sizeof(double);
    }
};

struct DlsValues {
    const double* values;
    const double& operator[](unsigned index) const { return values[index]; }
    const double* data() const { return values; }
};

extern "C" void dls_seed_original(DlsMatrixView&, const DlsValues&, const DlsValues&,
                                 const DlsValues&, const DlsValues&);
extern "C" void dls_seed_cached(DlsMatrixView&, const DlsValues&, const DlsValues&,
                               const DlsValues&, const DlsValues&);

#endif

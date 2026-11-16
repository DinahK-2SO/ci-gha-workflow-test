#define NO_IMPORT_ARRAY
#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
#include <Python.h>
#include <numpy/arrayobject.h>
#include <cstdio>
#include <limits>
#include <sys/types.h>

#if defined(_M_ARM64) && defined(NPY_CPU_ARMEL_AARCH64)
#define PROBE_ARCHITECTURE "ARM64"
#elif defined(_M_X64) && defined(NPY_CPU_AMD64)
#define PROBE_ARCHITECTURE "x64"
#else
#error The compiler and NumPy headers must agree on ARM64 or x64.
#endif

#define CHECK_NUMPY_SIZE(name, type) \
    static_assert(NPY_SIZEOF_##name == sizeof(type), "NumPy ABI mismatch: " #name)

CHECK_NUMPY_SIZE(SHORT, short);
CHECK_NUMPY_SIZE(INT, int);
CHECK_NUMPY_SIZE(LONG, long);
CHECK_NUMPY_SIZE(FLOAT, float);
CHECK_NUMPY_SIZE(COMPLEX_FLOAT, npy_cfloat);
CHECK_NUMPY_SIZE(DOUBLE, double);
CHECK_NUMPY_SIZE(COMPLEX_DOUBLE, npy_cdouble);
CHECK_NUMPY_SIZE(LONGDOUBLE, long double);
CHECK_NUMPY_SIZE(COMPLEX_LONGDOUBLE, npy_clongdouble);
CHECK_NUMPY_SIZE(PY_INTPTR_T, Py_intptr_t);
CHECK_NUMPY_SIZE(INTP, npy_intp);
CHECK_NUMPY_SIZE(UINTP, npy_uintp);
CHECK_NUMPY_SIZE(WCHAR_T, wchar_t);
CHECK_NUMPY_SIZE(OFF_T, off_t);
CHECK_NUMPY_SIZE(PY_LONG_LONG, PY_LONG_LONG);
CHECK_NUMPY_SIZE(LONGLONG, long long);
static_assert(sizeof(npy_intp) == sizeof(Py_ssize_t));
static_assert(NPY_BYTE_ORDER == NPY_LITTLE_ENDIAN);
static_assert(std::numeric_limits<long double>::is_iec559);
static_assert(std::numeric_limits<long double>::digits == 53);

int main()
{
    std::printf(PROBE_ARCHITECTURE " NumPy C-API header ABI validated\n");
    std::printf("Python: %s\n", Py_GetVersion());
    std::printf("NumPy ABI/API: 0x%08x / 0x%08x\n", NPY_ABI_VERSION, NPY_API_VERSION);
    std::printf("Native NumPy runtime import: NOT TESTED\n");
    return 0;
}

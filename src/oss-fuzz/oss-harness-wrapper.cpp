#include <cstdio>
#include <cstdint>
#include <vector>
#include <sys/stat.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
    if (argc < 2) return 0;
    const char *path = argv[1];
    FILE *f = fopen(path, "rb");
    if (!f) return 0;

    struct stat st;
    if (fstat(fileno(f), &st) != 0) { fclose(f); return 0; }

    size_t size = (size_t)st.st_size;
    std::vector<uint8_t> data_vec(size ? size : 1);

    if (size > 0) {
        size_t r = fread(data_vec.data(), 1, size, f);
        (void)r;
    }

    fclose(f);

    LLVMFuzzerTestOneInput(data_vec.data(), size);
    return 0;
}

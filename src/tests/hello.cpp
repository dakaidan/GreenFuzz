#include <cstdio>
#include <cstdlib>
#include <cmath>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <input_file>\n", argv[0]);
        return 1;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;

    unsigned char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);

    // Do some work based on input so RAPL can measure
    volatile double sum = 0.0;
    for (size_t i = 0; i < n; ++i) {
        for (int j = 0; j < 10000; ++j) {
            sum += buf[i] * 0.001 * j;
        }
    }

    return 0;
}


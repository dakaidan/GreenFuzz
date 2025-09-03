#include <cstdio>
#include <cppJoules.h>
#include <cinttypes>
#include <sys/shm.h>
#include <sstream>
#include <iostream>
#include <string>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>

#ifdef AFL_ENERGY_MAPPING
static volatile uint64_t *cpu_energy_map = nullptr;
static volatile uint64_t *mem_energy_map = nullptr;
#endif

#ifdef AFL_ENERGY_MAPPING
static void init_energy_map() {
    const char *cpu_id_str = getenv("AFL_CPU_ENERGY_SHM_ID");
    if (!cpu_id_str) return;
    const int cpu_shmid = atoi(cpu_id_str);
    void *cpu_shm = shmat(cpu_shmid, nullptr, 0);
    if (cpu_shm == (void *)-1) return;
    cpu_energy_map = (volatile uint64_t *)cpu_shm;

    const char *mem_id_str = getenv("AFL_MEM_ENERGY_SHM_ID");
    if (!mem_id_str) return;
    const int mem_shmid = atoi(mem_id_str);
    void *mem_shm = shmat(mem_shmid, nullptr, 0);
    if (mem_shm == (void *)-1) return;
    mem_energy_map = (volatile uint64_t *)mem_shm;
}
#endif

#ifdef AFL_ENERGY_MAPPING
void afl_set_energy_score(const uint64_t cpu_val, const uint64_t mem_val) {
    if (!cpu_energy_map || !mem_energy_map) init_energy_map();
    if (cpu_energy_map) {
        *cpu_energy_map = cpu_val;
    }
    if (mem_energy_map) {
        *mem_energy_map = mem_val;
    }
}
#endif

#ifdef AFL_FORCE_PRINT
static void reopen_stdout() {
    int fd = open("/dev/tty", O_WRONLY);
    if (fd != -1) {
        dup2(fd, STDOUT_FILENO);
        close(fd);
    }
    fflush(stdout);
}
#endif

static EnergyTracker* tracker = nullptr;

static void run_cleanup() {
    #ifdef AFL_FORCE_PRINT
    reopen_stdout();
    #endif
    fprintf(stderr, "[preload] After main()\n");

    if (tracker) {
        tracker->stop();

        tracker->calculate_energy();

        std::ostringstream oss;
        std::streambuf *old_buf = std::cout.rdbuf(oss.rdbuf());
        tracker->print_energy();
        std::cout.rdbuf(old_buf);

        std::string output = oss.str();
        std::istringstream iss(output);

        std::string line;
        double package = 0.0;
        double dram = 0.0;

        while (std::getline(iss, line)) {
            if (line.rfind("Time", 0) == 0) {
                continue;
            }
            size_t dash_pos = line.find('-');
            if (dash_pos != std::string::npos) {
                std::string name = line.substr(0, dash_pos);
                size_t space_pos = line.find(' ', dash_pos);
                if (space_pos != std::string::npos) {
                    std::string val_str = line.substr(space_pos + 1);
                    double val = std::stod(val_str);
                    if (name == "package") {
                        package += val;
                    } else if (name == "dram") {
                        dram += val;
                    }
                }
            }
        }

        auto microjoules = static_cast<uint64_t>((package + dram) * 1000000.0);
        auto package_micros = static_cast<uint64_t>(package * 1000000.0);
        auto dram_micros = static_cast<uint64_t>(dram * 1000000.0);

        fprintf(stdout, "[preload] Total energy = %.6f J (%" PRIu64 " uJ)\n", (package + dram), microjoules);
        fprintf(stdout, "[preload] Package energy = %.6f J (%" PRIu64 " uJ)\n", package, package_micros);
        fprintf(stdout, "[preload] DRAM energy = %.6f J (%" PRIu64 " uJ)\n", dram, dram_micros);

        #ifdef AFL_ENERGY_MAPPING
        afl_set_energy_score(package_micros, dram_micros);
        #endif

        delete tracker;
        tracker = nullptr;
    }
}

__attribute__((constructor))
static void preload_init() {
    fprintf(stderr, "[preload] Before main()\n");
    #ifndef AFL_ENERGY_MAPPING
    fprintf(stderr, "[preload] AFL_ENERGY_MAPPING not defined, will not set energy score\n");
    #endif

    tracker = new EnergyTracker();
    tracker->start();
}

__attribute__((destructor))
static void preload_fini() {
    run_cleanup();
}

extern "C" void exit(int status) {
    static void (*real_exit)(int) = nullptr;
    if (!real_exit) real_exit = (void (*)(int))dlsym(RTLD_NEXT, "exit");

    run_cleanup();
    real_exit(status);
}

extern "C" void _exit(int status) {
    static void (*real__exit)(int) = nullptr;
    if (!real__exit) real__exit = (void (*)(int))dlsym(RTLD_NEXT, "_exit");

    run_cleanup();
    real__exit(status);
}

extern "C" void _Exit(int status) {
    static void (*real__Exit)(int) = nullptr;
    if (!real__Exit) real__Exit = (void (*)(int))dlsym(RTLD_NEXT, "_Exit");

    run_cleanup();
    real__Exit(status);
}



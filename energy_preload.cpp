#include <cstdio>
#include <cppJoules.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/shm.h>
#include <stdint.h>

static volatile uint64_t *energy_map = NULL;

static void init_energy_map(void) {
    const char *id_str = getenv("AFL_ENERGY_SHM_ID");
    if (!id_str) return;
    int shmid = atoi(id_str);
    void *shm = shmat(shmid, NULL, 0);
    if (shm == (void *)-1) return;
    energy_map = (volatile uint64_t *)shm;
}

void afl_set_energy_score(uint64_t val) {
    if (!energy_map) init_energy_map();
    if (energy_map) {
        *energy_map = val;
    }
}

static EnergyTracker* tracker = nullptr;

__attribute__((constructor))
static void preload_init(void) {
    fprintf(stderr, "[preload] Before main()\n");

    tracker = new EnergyTracker();
    tracker->start();
}

__attribute__((destructor))
static void preload_fini(void) {
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
        double total = 0.0;

        while (std::getline(iss, line)) {
            if (line.rfind("Time", 0) == 0) {
                continue;
            }
            std::istringstream ls(line);
            std::string name;
            double val;
            if (ls >> name >> val) {
                total += val;
            }
        }

        uint64_t microjoules = static_cast<uint64_t>(total * 1000000.0);

        fprintf(stderr, "[preload] Total energy = %.6f J (%" PRIu64 " uJ)\n", total, microjoules);

        afl_set_energy_score(microjoules);

        delete tracker;
        tracker = nullptr;
    }
}


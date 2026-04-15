#include <stdio.h>
#include <time.h>

/// Runs when the appex Mach-O image loads (before Swift `FinderSync.init`). Session 55b33e debug.
__attribute__((constructor))
static void MediaDashFinderSyncDylibConstructor(void) {
    const char *path = "/tmp/MediaDashFinderSync-55b33e-constructor.txt";
    FILE *f = fopen(path, "a");
    if (f) {
        fprintf(f, "constructor ts=%ld session=55b33e\n", (long)time(NULL));
        fclose(f);
    }
}

// Native arm64 entry point of VoiceBud.app. A script as CFBundleExecutable
// makes macOS ask for Rosetta (it cannot tell a script's architecture), so
// this binary only hands over to Contents/Resources/launch.sh.
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    char exe[PATH_MAX], real[PATH_MAX], script[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL)
        return 1;
    snprintf(script, sizeof(script), "%s/../Resources/launch.sh", dirname(real));
    execl("/bin/zsh", "zsh", script, (char *)NULL);
    perror("VoiceBud: cannot start launch.sh");
    return 1;
}

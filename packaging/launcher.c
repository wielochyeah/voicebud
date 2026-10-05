/* VoiceBud.app main executable for the DMG build: runs the bundled Python IN this process, so
 * macOS attributes microphone, accessibility and input monitoring to VoiceBud itself (a launcher
 * that execs a shell or a python binary would hand the permissions to that binary instead).
 *
 * Without arguments it runs Resources/app/main.py and writes stdout/stderr to
 * ~/Library/Logs/voicebud.log. With arguments it behaves like the python interpreter. */
#include <Python.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    char exe[PATH_MAX], real[PATH_MAX], contents[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL) return 1;
    snprintf(contents, sizeof(contents), "%s/..", dirname(real));

    char home[PATH_MAX], app[PATH_MAX], ui[PATH_MAX];
    snprintf(home, sizeof(home), "%s/Resources/python", contents);
    snprintf(app, sizeof(app), "%s/Resources/app/main.py", contents);
    snprintf(ui, sizeof(ui), "%s/Resources/VoiceBudUI.app/Contents/MacOS/VoiceBudUI", contents);
    setenv("VOICEBUD_UI", ui, 1);
    setenv("PYTHONNOUSERSITE", "1", 1);

    if (argc == 1) {
        const char *user = getenv("HOME");
        if (user != NULL) {
            char log[PATH_MAX];
            snprintf(log, sizeof(log), "%s/Library/Logs/voicebud.log", user);
            if (freopen(log, "a", stdout) == NULL || freopen(log, "a", stderr) == NULL) {
                /* keep the original streams */
            }
        }
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.buffered_stdio = 0;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) {
        if (argc == 1) {
            char *args[] = {argv[0], app};
            status = PyConfig_SetBytesArgv(&config, 2, args);
        } else {
            status = PyConfig_SetBytesArgv(&config, argc, argv);
        }
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) Py_ExitStatusException(status);
    return Py_RunMain();
}

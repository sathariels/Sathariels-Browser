#import "LumenScriptHandler.h"
#import <signal.h>
#import <unistd.h>

static int LumenCrashFD = -1;

void LumenInstallCrashNote(const char *path) {
    if (LumenCrashFD >= 0 || path == NULL) return;
    LumenCrashFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void LumenCrashSignal(int code) {
    char buffer[12] = "signal ??\n";
    buffer[7] = '0' + ((code / 10) % 10);
    buffer[8] = '0' + (code % 10);
    if (LumenCrashFD >= 0) write(LumenCrashFD, buffer, 10);
    signal(code, SIG_DFL);
    raise(code);
}

void LumenInstallSignals(void) {
    signal(SIGABRT, LumenCrashSignal);
    signal(SIGSEGV, LumenCrashSignal);
    signal(SIGBUS, LumenCrashSignal);
    signal(SIGILL, LumenCrashSignal);
}

BOOL LumenAddScriptMessageHandler(WKUserContentController *controller, id<WKScriptMessageHandler> handler, NSString *name) {
    @try {
        [controller addScriptMessageHandler:handler name:name];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

void LumenRemoveScriptMessageHandler(WKUserContentController *controller, NSString *name) {
    @try {
        [controller removeScriptMessageHandlerForName:name];
    } @catch (NSException *exception) {
    }
}

#import <WebKit/WebKit.h>

/// Returns YES when the handler was added. Returns NO when that name is already
/// registered. WebKit raises NSException for a duplicate, which would abort the process.
BOOL LumenAddScriptMessageHandler(WKUserContentController *controller, id<WKScriptMessageHandler> handler, NSString *name);

/// Removes a handler when it is present. A missing name raises, so the exception is ignored.
void LumenRemoveScriptMessageHandler(WKUserContentController *controller, NSString *name);
void LumenInstallCrashNote(const char *path);
void LumenInstallSignals(void);
void LumenInstallExceptionHandler(void);

#import "LumenScriptHandler.h"

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

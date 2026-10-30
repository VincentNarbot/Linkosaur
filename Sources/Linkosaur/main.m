#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <arpa/inet.h>

static NSString *const LinkosaurBundleIdentifier = @"app.linkosaur.Linkosaur";
static NSString *const WorkBrowserKey = @"WorkBrowserBundleIdentifier";
static NSString *const PersonalBrowserKey = @"PersonalBrowserBundleIdentifier";
static NSString *const RulesKey = @"RoutingRules";
static NSString *const DefaultActionKey = @"DefaultRoutingAction";
static NSString *const HasPromptedKey = @"HasPromptedForDefaultBrowser";

static NSString *const ActionWork = @"work";
static NSString *const ActionPersonal = @"personal";
static NSString *const ActionAsk = @"ask";
static NSString *const ActionSafe = @"safe";

static NSString *const SafeDownloadNote = @"Downloads are blocked in the sandbox.";

// Runs in its own content world, so page scripts cannot see or undo it.
static NSString *const SafePasswordScript =
    @"(() => {"
     "const locked = new WeakSet(), notes = new WeakMap(), roots = new WeakSet();"
     "const isPassword = el => !!el && el.tagName === 'INPUT' && (locked.has(el) || el.type === 'password');"
     "const lock = el => {"
     "  locked.add(el);"
     "  if (el.value) el.value = '';"
     "  if (!el.disabled) el.disabled = true;"
     "  let note = notes.get(el);"
     "  if (!note) {"
     "    note = document.createElement('span');"
     "    note.textContent = 'Passwords are blocked in the sandbox.';"
     "    note.style.cssText = 'display:block;margin:4px 0;color:#c4291c;font:12px -apple-system,sans-serif';"
     "    notes.set(el, note);"
     "  }"
     "  if (!note.isConnected) el.after(note);"
     "};"
     "const scan = root => {"
     "  if (!root.querySelectorAll) return;"
     "  if (isPassword(root)) lock(root);"
     "  for (const el of root.querySelectorAll('*')) {"
     "    if (isPassword(el)) lock(el);"
     "    if (el.shadowRoot && !roots.has(el.shadowRoot)) watch(el.shadowRoot);"
     "  }"
     "};"
     "const observer = new MutationObserver(records => {"
     "  for (const r of records) r.type === 'attributes' ? (isPassword(r.target) && lock(r.target)) : r.addedNodes.forEach(scan);"
     "});"
     "const watch = root => {"
     "  roots.add(root);"
     "  observer.observe(root, {subtree: true, childList: true, attributes: true, attributeFilter: ['type', 'disabled', 'value']});"
     "  scan(root);"
     "};"
     "watch(document);"
     "document.addEventListener('focusin', e => { const el = e.composedPath()[0]; if (isPassword(el)) lock(el); }, true);"
     "document.addEventListener('submit', e => {"
     "  if (Array.from(e.target.elements || []).some(isPassword)) { e.preventDefault(); e.stopImmediatePropagation(); }"
     "}, true);"
     "})();";

static BOOL IsLocalIPv4(uint32_t a) {
    return (a >> 24) == 0 || (a >> 24) == 10 || (a >> 24) == 127 || (a >> 24) >= 224 ||
           (a >> 20) == 0xAC1 || (a >> 16) == 0xC0A8 || (a >> 16) == 0xA9FE || (a >> 22) == (0x64400000u >> 22);
}

// Hosts on this Mac or the local network: local names, single-label names, private/loopback/link-local IPs.
static BOOL IsLocalHost(NSString *rawHost) {
    NSString *host = rawHost.lowercaseString ?: @"";
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (host.length == 0) return YES;

    struct in_addr v4;
    if (inet_aton(host.UTF8String, &v4) == 1) return IsLocalIPv4(ntohl(v4.s_addr));
    struct in6_addr v6;
    if (inet_pton(AF_INET6, [host componentsSeparatedByString:@"%"].firstObject.UTF8String, &v6) == 1) {
        const uint8_t *b = v6.s6_addr;
        static const uint8_t compatible[12] = {0}, mapped[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff},
                             nat64[12] = {0,0x64,0xff,0x9b};
        if (memcmp(b, compatible, 12) == 0 || memcmp(b, mapped, 12) == 0 || memcmp(b, nat64, 12) == 0) {
            return IsLocalIPv4((uint32_t)b[12] << 24 | (uint32_t)b[13] << 16 | (uint32_t)b[14] << 8 | b[15]);
        }
        return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0x80)) || b[0] == 0xff;
    }

    if (![host containsString:@"."]) return YES;
    for (NSString *suffix in @[@"localhost", @"local", @"internal", @"lan", @"home.arpa"]) {
        if ([host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]]) return YES;
    }
    return NO;
}

static BOOL IsWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSString *SafeBlockReason(NSURL *url) {
    if ([url.scheme.lowercaseString isEqualToString:@"about"]) return nil;
    if (!IsWebURL(url)) return @"Only web links open in the sandbox.";
    if (IsLocalHost(url.host)) return [NSString stringWithFormat:@"Blocked %@: it is on this Mac or the local network.", url.host ?: @"link"];
    return nil;
}

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SafeWindow : NSObject <NSWindowDelegate, WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSButton *backButton;
@property(nonatomic, strong) NSButton *forwardButton;
@property(nonatomic, strong) NSTextField *hostLabel;
@property(nonatomic, strong) NSTextField *urlLabel;
@property(nonatomic, strong) NSTextField *noteLabel;
@property(nonatomic, copy) void (^openInBrowser)(NSURL *url);
@property(nonatomic, copy) void (^didClose)(SafeWindow *safeWindow);
@end

@implementation SafeWindow

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (!self) return nil;

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [configuration.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:SafePasswordScript
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:NO
                              inContentWorld:[WKContentWorld worldWithName:@"LinkosaurSafeWindow"]]];
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    for (NSString *key in @[@"URL", @"canGoBack", @"canGoForward"]) {
        [self.webView addObserver:self forKeyPath:key options:0 context:nil];
    }

    self.backButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Back"]
                                         target:self.webView action:@selector(goBack:)];
    self.forwardButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Forward"]
                                            target:self.webView action:@selector(goForward:)];
    self.backButton.bordered = self.forwardButton.bordered = NO;

    self.hostLabel = [NSTextField labelWithString:@""];
    self.hostLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightBold];
    self.urlLabel = [NSTextField labelWithString:@""];
    self.urlLabel.font = [NSFont systemFontOfSize:11];
    self.urlLabel.textColor = NSColor.secondaryLabelColor;
    for (NSTextField *label in @[self.hostLabel, self.urlLabel]) {
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [label setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSStackView *address = [NSStackView stackViewWithViews:@[self.hostLabel, self.urlLabel]];
    address.orientation = NSUserInterfaceLayoutOrientationVertical;
    address.alignment = NSLayoutAttributeLeading;
    address.spacing = 1;
    [address setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.noteLabel = [NSTextField labelWithString:@""];
    self.noteLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.noteLabel.textColor = NSColor.systemOrangeColor;
    self.noteLabel.hidden = YES;
    NSButton *open = [NSButton buttonWithTitle:@"Open in browser" target:self action:@selector(openInBrowserClicked)];

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[self.backButton, self.forwardButton, address, self.noteLabel, open]];
    toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.alignment = NSLayoutAttributeCenterY;
    toolbar.distribution = NSStackViewDistributionFill;
    toolbar.spacing = 10;
    toolbar.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
    NSBox *line = [[NSBox alloc] init];
    line.boxType = NSBoxSeparator;
    NSStackView *content = [NSStackView stackViewWithViews:@[toolbar, line, self.webView]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeWidth;
    content.spacing = 0;

    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1100, 780)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.contentView = content;
    [self updateAddressForURL:url];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window orderFrontRegardless];
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    return self;
}

- (void)updateAddressForURL:(NSURL *)url {
    self.hostLabel.stringValue = url.host ?: @"";
    self.urlLabel.stringValue = url.absoluteString ?: @"";
    self.window.title = url.host.length ? url.host : @"Sandbox";
    self.backButton.enabled = self.webView.canGoBack;
    self.forwardButton.enabled = self.webView.canGoForward;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (self.webView.URL) [self updateAddressForURL:self.webView.URL];
}

- (void)showNote:(NSString *)note {
    self.noteLabel.stringValue = note ?: @"";
    self.noteLabel.hidden = note == nil;
}

- (void)openInBrowserClicked {
    NSURL *url = self.webView.URL;
    if (IsWebURL(url) && self.openInBrowser) self.openInBrowser(url);
}

- (void)windowWillClose:(NSNotification *)notification {
    for (NSString *key in @[@"URL", @"canGoBack", @"canGoForward"]) [self.webView removeObserver:self forKeyPath:key];
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    if (self.didClose) self.didClose(self);
}

#pragma mark WebKit policy

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                                                     decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *reason = SafeBlockReason(navigationAction.request.URL);
    if (!reason && navigationAction.shouldPerformDownload) reason = SafeDownloadNote;
    if (reason && (navigationAction.shouldPerformDownload || !navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame)) {
        [self showNote:reason];
    }
    decisionHandler(reason ? WKNavigationActionPolicyCancel : WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                                                       decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSString *disposition = [navigationResponse.response isKindOfClass:NSHTTPURLResponse.class]
        ? [(NSHTTPURLResponse *)navigationResponse.response valueForHTTPHeaderField:@"Content-Disposition"] : nil;
    BOOL download = !navigationResponse.canShowMIMEType || [disposition.lowercaseString hasPrefix:@"attachment"];
    if (download) [self showNote:SafeDownloadNote];
    decisionHandler(download ? WKNavigationResponsePolicyCancel : WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    [self showNote:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
}

- (void)webView:(WKWebView *)webView requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                                                          initiatedByFrame:(WKFrameInfo *)frame
                                                                      type:(WKMediaCaptureType)type
                                                           decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
    decisionHandler(WKPermissionDecisionDeny);
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
                                               initiatedByFrame:(WKFrameInfo *)frame
                                              completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
    completionHandler(nil);
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *defaultStatusLabel;
@property(nonatomic, strong) NSImageView *defaultStatusIcon;
@property(nonatomic, strong) NSButton *defaultButton;
@property(nonatomic, strong) NSPopUpButton *workBrowserPopup;
@property(nonatomic, strong) NSPopUpButton *personalBrowserPopup;
@property(nonatomic, strong) NSPopUpButton *defaultActionPopup;
@property(nonatomic, strong) NSStackView *rulesStack;
@property(nonatomic, strong) NSView *rulesDocumentView;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *rules;
@property(nonatomic, strong) NSArray<NSDictionary *> *availableBrowsers;
@property(nonatomic, strong) NSMutableArray<SafeWindow *> *safeWindows;
@property(nonatomic) BOOL receivedURLDuringLaunch;
@end

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *initialRules = @[
            [@{@"pattern": @"formidable.care", @"action": ActionWork} mutableCopy],
            [@{@"pattern": @"github.com", @"action": ActionWork} mutableCopy],
            [@{@"pattern": @"aws.amazon.com", @"action": ActionWork} mutableCopy],
            [@{@"pattern": @"amazonaws.com", @"action": ActionWork} mutableCopy],
            [@{@"pattern": @"awsapps.com", @"action": ActionWork} mutableCopy],
            [@{@"pattern": @"google.com", @"action": ActionAsk} mutableCopy]
        ];
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            WorkBrowserKey: @"com.google.Chrome",
            PersonalBrowserKey: @"com.apple.Safari",
            DefaultActionKey: ActionPersonal,
            RulesKey: initialRules
        }];
        _rules = [NSMutableArray array];
        _safeWindows = [NSMutableArray array];
        for (NSDictionary *rule in [[NSUserDefaults standardUserDefaults] arrayForKey:RulesKey]) {
            [_rules addObject:[rule mutableCopy]];
        }
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [[NSAppleEventManager sharedAppleEventManager]
        setEventHandler:self
             andSelector:@selector(handleGetURLEvent:withReplyEvent:)
           forEventClass:kInternetEventClass
              andEventID:kAEGetURL];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.availableBrowsers = [self discoverBrowsers];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.receivedURLDuringLaunch) {
            [self showWindow];
            if (![[NSUserDefaults standardUserDefaults] boolForKey:HasPromptedKey] && ![self isDefaultBrowser]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:HasPromptedKey];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self makeDefaultBrowser]; });
            }
        }
    });
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showWindow];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NSAppleEventManager sharedAppleEventManager]
        removeEventHandlerForEventClass:kInternetEventClass
                              andEventID:kAEGetURL];
}

#pragma mark - Routing

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event
           withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
    self.receivedURLDuringLaunch = YES;
    NSString *value = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    NSURL *url = value ? [NSURL URLWithString:value] : nil;
    if (![url.scheme.lowercaseString isEqualToString:@"linkosaur"]) {
        if (url) [self routeURL:url allowSafeWindow:YES];
        return;
    }
    if (![url.host.lowercaseString isEqualToString:@"safe"]) return;
    NSString *target = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"url"]) target = item.value;
    }
    NSURL *safeURL = target ? [NSURL URLWithString:target] : nil;
    if (IsWebURL(safeURL)) [self openSafeWindowWithURL:safeURL];
    else [self showError:@"The sandbox only opens http and https links."];
}

- (BOOL)host:(NSString *)host matchesPattern:(NSString *)rawPattern {
    NSString *pattern = [[rawPattern stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                         lowercaseString];
    if (pattern.length == 0) return NO;

    if ([pattern containsString:@"://"]) {
        NSURL *patternURL = [NSURL URLWithString:pattern];
        if (patternURL.host.length > 0) pattern = patternURL.host.lowercaseString;
    }
    if ([pattern hasPrefix:@"*."]) pattern = [pattern substringFromIndex:2];
    NSRange slash = [pattern rangeOfString:@"/"];
    if (slash.location != NSNotFound) pattern = [pattern substringToIndex:slash.location];
    while ([pattern hasSuffix:@"."]) pattern = [pattern substringToIndex:pattern.length - 1];

    return [host isEqualToString:pattern] || [host hasSuffix:[@"." stringByAppendingString:pattern]];
}

- (NSString *)actionForURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSDictionary *rule in self.rules) {
        if ([self host:host matchesPattern:rule[@"pattern"] ?: @""]) {
            return rule[@"action"] ?: ActionPersonal;
        }
    }
    return [[NSUserDefaults standardUserDefaults] stringForKey:DefaultActionKey] ?: ActionPersonal;
}

// Links leaving a safe window ("Open in browser") must never land back in one.
- (void)routeURL:(NSURL *)url allowSafeWindow:(BOOL)allowSafeWindow {
    NSString *action = [self actionForURL:url];
    if ([action isEqualToString:ActionSafe] && !allowSafeWindow) action = ActionAsk;
    if (![@[ActionWork, ActionPersonal, ActionSafe] containsObject:action]) {
        action = [self askActionForURL:url allowSafeWindow:allowSafeWindow];
    }
    if (!action) return;
    if ([action isEqualToString:ActionSafe]) {
        [self openSafeWindowWithURL:url];
        return;
    }
    NSString *bundleID = [NSUserDefaults.standardUserDefaults
                          stringForKey:[action isEqualToString:ActionWork] ? WorkBrowserKey : PersonalBrowserKey];
    if (!bundleID) return;

    NSURL *applicationURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
    if (!applicationURL) {
        [self showError:[NSString stringWithFormat:@"The selected browser (%@) is not installed.", bundleID]];
        return;
    }

    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    [NSWorkspace.sharedWorkspace openURLs:@[url]
                      withApplicationAtURL:applicationURL
                            configuration:configuration
                        completionHandler:^(NSRunningApplication *application, NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ [self showError:error.localizedDescription]; });
    }];
}

- (void)openSafeWindowWithURL:(NSURL *)url {
    SafeWindow *safeWindow = [[SafeWindow alloc] initWithURL:url];
    __weak typeof(self) weakSelf = self;
    safeWindow.openInBrowser = ^(NSURL *pageURL) { [weakSelf routeURL:pageURL allowSafeWindow:NO]; };
    safeWindow.didClose = ^(SafeWindow *closed) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.safeWindows removeObject:closed]; });
    };
    [self.safeWindows addObject:safeWindow];
}

- (NSString *)askActionForURL:(NSURL *)url allowSafeWindow:(BOOL)allowSafeWindow {
    NSString *workID = [NSUserDefaults.standardUserDefaults stringForKey:WorkBrowserKey];
    NSString *personalID = [NSUserDefaults.standardUserDefaults stringForKey:PersonalBrowserKey];
    NSString *workName = [self browserNameForBundleIdentifier:workID] ?: @"Work browser";
    NSString *personalName = [self browserNameForBundleIdentifier:personalID] ?: @"Personal browser";

    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = url.host ?: @"This link";
    alert.informativeText = url.absoluteString;
    [alert addButtonWithTitle:[NSString stringWithFormat:@"Open in Work — %@", workName]];
    [alert addButtonWithTitle:[NSString stringWithFormat:@"Open in Personal — %@", personalName]];
    if (allowSafeWindow) [alert addButtonWithTitle:@"Open in a sandbox"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) return ActionWork;
    if (response == NSAlertSecondButtonReturn) return ActionPersonal;
    if (allowSafeWindow && response == NSAlertThirdButtonReturn) return ActionSafe;
    return nil;
}

#pragma mark - Browser discovery and defaults

- (NSArray<NSDictionary *> *)discoverBrowsers {
    NSURL *webURL = [NSURL URLWithString:@"https://example.com/"];
    NSArray<NSURL *> *applicationURLs = [NSWorkspace.sharedWorkspace URLsForApplicationsToOpenURL:webURL];
    NSMutableDictionary<NSString *, NSDictionary *> *byIdentifier = [NSMutableDictionary dictionary];
    for (NSURL *url in applicationURLs) {
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSString *identifier = bundle.bundleIdentifier;
        if (!identifier || [identifier isEqualToString:LinkosaurBundleIdentifier] ||
            [identifier isEqualToString:@"care.formidable.LinkRouter"]) continue;
        NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: 
                         [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: url.lastPathComponent.stringByDeletingPathExtension;
        byIdentifier[identifier] = @{@"id": identifier, @"name": name, @"url": url};
    }
    return [byIdentifier.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
}

- (NSString *)browserNameForBundleIdentifier:(NSString *)identifier {
    for (NSDictionary *browser in self.availableBrowsers) {
        if ([browser[@"id"] isEqualToString:identifier]) return browser[@"name"];
    }
    NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    return url.lastPathComponent.stringByDeletingPathExtension;
}

- (BOOL)isDefaultBrowser {
    NSURL *handlerURL = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com/"]];
    return [[NSBundle bundleWithURL:handlerURL].bundleIdentifier isEqualToString:LinkosaurBundleIdentifier];
}

- (void)makeDefaultBrowser {
    NSURL *applicationURL = NSBundle.mainBundle.bundleURL;
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:applicationURL
                                       toOpenURLsWithScheme:@"http"
                                          completionHandler:^(NSError *httpError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (httpError) { [self showError:httpError.localizedDescription]; return; }
            [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:applicationURL
                                               toOpenURLsWithScheme:@"https"
                                                  completionHandler:^(NSError *httpsError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (httpsError) [self showError:httpsError.localizedDescription];
                    [self updateDefaultStatus];
                });
            }];
        });
    }];
}

#pragma mark - Settings UI

- (void)showWindow {
    if (!self.window) self.window = [self makeWindow];
    [self updateDefaultStatus];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSTextField *)sectionLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    return label;
}

- (NSBox *)separator {
    NSBox *box = [[NSBox alloc] init];
    box.boxType = NSBoxSeparator;
    return box;
}

- (NSPopUpButton *)browserPopupWithSelectedIdentifier:(NSString *)selected tag:(NSInteger)tag {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.tag = tag;
    popup.target = self;
    popup.action = @selector(browserSelectionChanged:);
    for (NSDictionary *browser in self.availableBrowsers) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:browser[@"name"] action:nil keyEquivalent:@""];
        item.representedObject = browser[@"id"];
        [popup.menu addItem:item];
        if ([browser[@"id"] isEqualToString:selected]) [popup selectItem:item];
    }
    if (!popup.selectedItem && selected) {
        NSMenuItem *missing = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Unavailable — %@", selected]
                                                        action:nil keyEquivalent:@""];
        missing.representedObject = selected;
        [popup.menu addItem:missing];
        [popup selectItem:missing];
    }
    return popup;
}

- (NSPopUpButton *)actionPopupWithSelectedAction:(NSString *)selected tag:(NSInteger)tag selector:(SEL)selector {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.tag = tag;
    popup.target = self;
    popup.action = selector;
    NSArray *choices = @[
        @{@"title": @"Work browser", @"value": ActionWork},
        @{@"title": @"Personal browser", @"value": ActionPersonal},
        @{@"title": @"Sandbox", @"value": ActionSafe},
        @{@"title": @"Ask every time", @"value": ActionAsk}
    ];
    for (NSDictionary *choice in choices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:choice[@"title"] action:nil keyEquivalent:@""];
        item.representedObject = choice[@"value"];
        [popup.menu addItem:item];
        if ([choice[@"value"] isEqualToString:selected]) [popup selectItem:item];
    }
    return popup;
}

- (NSView *)labeledRow:(NSString *)label control:(NSView *)control {
    NSTextField *text = [NSTextField labelWithString:label];
    text.alignment = NSTextAlignmentRight;
    [text.widthAnchor constraintEqualToConstant:120].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[text, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    [control.widthAnchor constraintEqualToConstant:300].active = YES;
    return row;
}

- (NSStackView *)sectionHeaderWithTitle:(NSString *)title detail:(NSString *)detail {
    NSTextField *heading = [self sectionLabel:title];
    NSTextField *help = [NSTextField labelWithString:detail];
    help.textColor = NSColor.secondaryLabelColor;
    help.font = [NSFont systemFontOfSize:12.5];
    NSStackView *stack = [NSStackView stackViewWithViews:@[heading, help]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 3;
    return stack;
}

- (NSWindow *)makeWindow {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 720, 680)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Linkosaur Settings";
    window.releasedWhenClosed = NO;

    NSImageView *icon = [[NSImageView alloc] init];
    icon.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [icon.widthAnchor constraintEqualToConstant:52].active = YES;
    [icon.heightAnchor constraintEqualToConstant:52].active = YES;

    NSTextField *title = [NSTextField labelWithString:@"Linkosaur"];
    title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    NSTextField *subtitle = [NSTextField labelWithString:@"Send every link to the right browser."];
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *titleText = [NSStackView stackViewWithViews:@[title, subtitle]];
    titleText.orientation = NSUserInterfaceLayoutOrientationVertical;
    titleText.alignment = NSLayoutAttributeLeading;
    titleText.spacing = 3;
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titleText]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 14;

    NSImageView *statusIcon = [[NSImageView alloc] init];
    statusIcon.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:nil];
    statusIcon.contentTintColor = NSColor.systemGreenColor;
    [statusIcon.widthAnchor constraintEqualToConstant:17].active = YES;
    [statusIcon.heightAnchor constraintEqualToConstant:17].active = YES;
    self.defaultStatusIcon = statusIcon;
    self.defaultStatusLabel = [NSTextField labelWithString:@""];
    self.defaultStatusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.defaultButton = [NSButton buttonWithTitle:@"Make Default Browser" target:self action:@selector(makeDefaultBrowser)];
    self.defaultButton.controlSize = NSControlSizeSmall;
    NSStackView *statusText = [NSStackView stackViewWithViews:@[statusIcon, self.defaultStatusLabel]];
    statusText.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusText.alignment = NSLayoutAttributeCenterY;
    statusText.spacing = 7;
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[statusText, self.defaultButton]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.spacing = 16;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.workBrowserPopup = [self browserPopupWithSelectedIdentifier:[defaults stringForKey:WorkBrowserKey] tag:1];
    self.personalBrowserPopup = [self browserPopupWithSelectedIdentifier:[defaults stringForKey:PersonalBrowserKey] tag:2];
    NSStackView *browserRows = [NSStackView stackViewWithViews:@[
        [self labeledRow:@"Work browser" control:self.workBrowserPopup],
        [self labeledRow:@"Personal browser" control:self.personalBrowserPopup]
    ]];
    browserRows.orientation = NSUserInterfaceLayoutOrientationVertical;
    browserRows.alignment = NSLayoutAttributeLeading;
    browserRows.spacing = 8;

    self.rulesStack = [NSStackView stackViewWithViews:@[]];
    self.rulesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rulesStack.alignment = NSLayoutAttributeLeading;
    self.rulesStack.spacing = 6;
    self.rulesStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.rulesDocumentView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 650, MAX(208, self.rules.count * 40 + 16))];
    self.rulesDocumentView.autoresizingMask = NSViewWidthSizable;
    [self.rulesDocumentView addSubview:self.rulesStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.rulesStack.leadingAnchor constraintEqualToAnchor:self.rulesDocumentView.leadingAnchor constant:10],
        [self.rulesStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.rulesDocumentView.trailingAnchor constant:-10],
        [self.rulesStack.topAnchor constraintEqualToAnchor:self.rulesDocumentView.topAnchor constant:10]
    ]];
    [self rebuildRuleRows];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = NSColor.controlBackgroundColor;
    scroll.borderType = NSNoBorder;
    scroll.wantsLayer = YES;
    scroll.layer.cornerRadius = 8;
    scroll.documentView = self.rulesDocumentView;
    [scroll.heightAnchor constraintEqualToConstant:214].active = YES;

    NSTextField *domainHeader = [NSTextField labelWithString:@"DOMAIN"];
    domainHeader.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    domainHeader.textColor = NSColor.tertiaryLabelColor;
    [domainHeader.widthAnchor constraintEqualToConstant:372].active = YES;
    NSTextField *actionHeader = [NSTextField labelWithString:@"OPEN WITH"];
    actionHeader.font = domainHeader.font;
    actionHeader.textColor = domainHeader.textColor;
    [actionHeader.widthAnchor constraintEqualToConstant:170].active = YES;
    NSStackView *columnHeaders = [NSStackView stackViewWithViews:@[domainHeader, actionHeader]];
    columnHeaders.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columnHeaders.spacing = 9;

    NSButton *addButton = [NSButton buttonWithTitle:@"Add Rule" target:self action:@selector(addRule)];
    addButton.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
    addButton.imagePosition = NSImageLeading;
    addButton.controlSize = NSControlSizeSmall;

    self.defaultActionPopup = [self actionPopupWithSelectedAction:[defaults stringForKey:DefaultActionKey]
                                                               tag:0 selector:@selector(defaultActionChanged:)];
    NSView *fallbackRow = [self labeledRow:@"Default open with" control:self.defaultActionPopup];

    NSStackView *browserSection = [NSStackView stackViewWithViews:@[
        [self sectionHeaderWithTitle:@"Browsers" detail:@"Assign a browser to each side of your digital life."],
        browserRows
    ]];
    browserSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    browserSection.alignment = NSLayoutAttributeLeading;
    browserSection.spacing = 12;

    NSStackView *rulesSection = [NSStackView stackViewWithViews:@[
        [self sectionHeaderWithTitle:@"Routing Rules" detail:@"Domains include their subdomains. The first matching rule wins."],
        columnHeaders, scroll, addButton
    ]];
    rulesSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    rulesSection.alignment = NSLayoutAttributeLeading;
    rulesSection.spacing = 7;

    NSStackView *fallbackSection = [NSStackView stackViewWithViews:@[
        [self sectionHeaderWithTitle:@"Fallback" detail:@"Choose what happens when no domain rule matches."],
        fallbackRow
    ]];
    fallbackSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    fallbackSection.alignment = NSLayoutAttributeLeading;
    fallbackSection.spacing = 10;

    NSStackView *content = [NSStackView stackViewWithViews:@[
        header, statusRow, [self separator], browserSection,
        [self separator], rulesSection, [self separator], fallbackSection
    ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 13;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:28],
        [content.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-28],
        [content.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:22],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:window.contentView.bottomAnchor constant:-22],
        [statusRow.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [browserSection.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [rulesSection.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [fallbackSection.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [scroll.widthAnchor constraintEqualToAnchor:rulesSection.widthAnchor]
    ]];
    return window;
}

- (void)rebuildRuleRows {
    for (NSView *view in self.rulesStack.arrangedSubviews.copy) [self.rulesStack removeArrangedSubview:view], [view removeFromSuperview];
    for (NSInteger index = 0; index < self.rules.count; index++) {
        NSDictionary *rule = self.rules[index];
        NSTextField *pattern = [[NSTextField alloc] init];
        pattern.stringValue = rule[@"pattern"] ?: @"";
        pattern.placeholderString = @"example.com";
        pattern.tag = index;
        pattern.delegate = self;
        pattern.controlSize = NSControlSizeSmall;
        [pattern.widthAnchor constraintEqualToConstant:372].active = YES;

        NSPopUpButton *action = [self actionPopupWithSelectedAction:rule[@"action"] ?: ActionPersonal
                                                               tag:index selector:@selector(ruleActionChanged:)];
        action.controlSize = NSControlSizeSmall;
        [action.widthAnchor constraintEqualToConstant:170].active = YES;
        NSButton *remove = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus.circle" accessibilityDescription:@"Remove"]
                                              target:self action:@selector(removeRule:)];
        remove.tag = index;
        remove.bordered = NO;
        remove.contentTintColor = NSColor.secondaryLabelColor;
        NSStackView *row = [NSStackView stackViewWithViews:@[pattern, action, remove]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 9;
        [self.rulesStack addArrangedSubview:row];
    }
    CGFloat height = MAX(208, self.rules.count * 38 + 20);
    [self.rulesDocumentView setFrameSize:NSMakeSize(self.rulesDocumentView.frame.size.width, height)];
}

- (void)updateDefaultStatus {
    BOOL isDefault = [self isDefaultBrowser];
    self.defaultStatusLabel.stringValue = isDefault ? @"Active as your default browser router"
                                                    : @"Not currently your default browser router";
    self.defaultStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.defaultStatusIcon.image = [NSImage imageWithSystemSymbolName:(isDefault ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill")
                                             accessibilityDescription:nil];
    self.defaultStatusIcon.contentTintColor = isDefault ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    self.defaultButton.hidden = isDefault;
}

#pragma mark - Settings actions

- (void)browserSelectionChanged:(NSPopUpButton *)sender {
    NSString *key = sender.tag == 1 ? WorkBrowserKey : PersonalBrowserKey;
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject forKey:key];
}

- (void)defaultActionChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject forKey:DefaultActionKey];
}

- (void)ruleActionChanged:(NSPopUpButton *)sender {
    if (sender.tag < self.rules.count) {
        self.rules[sender.tag][@"action"] = sender.selectedItem.representedObject;
        [self saveRules];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    if (field.tag < self.rules.count) {
        self.rules[field.tag][@"pattern"] = field.stringValue;
        [self saveRules];
    }
}

- (void)addRule {
    [self.rules addObject:[@{@"pattern": @"", @"action": ActionWork} mutableCopy]];
    [self saveRules];
    [self rebuildRuleRows];
}

- (void)removeRule:(NSButton *)sender {
    if (sender.tag < self.rules.count) {
        [self.rules removeObjectAtIndex:sender.tag];
        [self saveRules];
        [self rebuildRuleRows];
    }
}

- (void)saveRules {
    [NSUserDefaults.standardUserDefaults setObject:self.rules forKey:RulesKey];
}

- (void)showError:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Linkosaur";
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleWarning;
    [alert runModal];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--route-test") == 0) {
            AppDelegate *tester = [[AppDelegate alloc] init];
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]];
            if (!url) return 2;
            printf("%s\n", [[tester actionForURL:url] UTF8String]);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}

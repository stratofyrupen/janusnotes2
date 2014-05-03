//
//  IAMNoteWindowController.m
// Turms
//
//  Created by Giacomo Tufano on 18/03/13.
//  Copyright (c) 2013 Giacomo Tufano. All rights reserved.
//

#import "IAMNoteEditorWC.h"

#import <WebKit/WebKit.h>

#import "IAMAppDelegate.h"
#import "Attachment.h"
#import "IAMOpenWithWC.h"
#import "Books.h"

@interface IAMNoteEditorWC () <NSWindowDelegate, NSCollectionViewDelegate> {
    BOOL _userConsentedToClose;
}

@property Note *editedNote;

@property IAMOpenWithWC *openWithController;
@property NSMutableArray *appsInfo;

@property (strong) IBOutlet NSArrayController *arrayController;
@property (strong) IBOutlet NSCollectionView *attachmentsCollectionView;

@property NSMutableArray *openedFiles;
@property (weak) IBOutlet NSLayoutConstraint *attacmentContainerViewHeightConstraint;
@property (weak) IBOutlet NSView *attachmentContainerView;

@property (weak) NSManagedObjectContext *parentMOC;

@property (strong) IBOutlet NSArrayController *booksArrayController;

@property (strong) IBOutlet NSWindow *previewWindow;
@property (weak) IBOutlet WebView *previewWebView;

@property (strong) NSURL *cacheDirectory;
@property (strong) NSURL *cacheFile;

@end

@implementation IAMNoteEditorWC

- (id)initWithWindow:(NSWindow *)window
{
    self = [super initWithWindow:window];
    if (self) {
    }
    
    return self;
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    _userConsentedToClose = NO;
    NSString *fontName = [[NSUserDefaults standardUserDefaults] stringForKey:@"fontName"];
    NSAssert(fontName, @"Default font not set in user defaults");
    double fontSize = [[NSUserDefaults standardUserDefaults] doubleForKey:@"fontSize"];
    self.editorFont = [NSFont fontWithName:fontName size:fontSize];
    // Load preview support files
    NSError *error;
    self.cacheDirectory = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    self.cacheFile = [self.cacheDirectory URLByAppendingPathComponent:@"preview.html"];
    // The NSManagedObjectContext instance should change for a local (to the controller instance) one.
    // We need to migrate the passed object to the new moc.
    self.noteEditorMOC = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    self.parentMOC = ((IAMAppDelegate *)[[NSApplication sharedApplication] delegate]).managedObjectContext;
    [self.noteEditorMOC setParentContext:self.parentMOC];
    // Prepare to receive drag & drops into CollectionView
    [self.attachmentsCollectionView registerForDraggedTypes:@[NSFilenamesPboardType]];
    [self.attachmentsCollectionView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    if (self.isCalledFromURL) {
        // called from URL to create a new note
        Note *newNote = [NSEntityDescription insertNewObjectForEntityForName:@"Note" inManagedObjectContext:self.noteEditorMOC];
        newNote.title = (self.calledTitle) ?: @"";
        newNote.text = (self.calledText) ?: @"";
        self.editedNote = newNote;
        // Now add attachment (if any)
        if (self.calledURL && ![self.calledURL isEqualToString:@""]) {
            DLog(@"This is addLinkViewController: didAddThisLink: for '%@'", self.calledURL);
            Attachment *newAttachment = [NSEntityDescription insertNewObjectForEntityForName:@"Attachment" inManagedObjectContext:self.noteEditorMOC];
            newAttachment.uti = (__bridge NSString *)(kUTTypeURL);
            newAttachment.extension = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass(kUTTypeURL, kUTTagClassFilenameExtension);
            if(!newAttachment.extension)
                newAttachment.extension = @"url";
            newAttachment.filename = [NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], newAttachment.extension];
            newAttachment.type = @"Link";
            NSString *attachmentContent = [NSString stringWithFormat:@"[InternetShortcut]\nURL=%@\n", self.calledURL];
            newAttachment.data = [attachmentContent dataUsingEncoding:NSUTF8StringEncoding];
            // Now link attachment to the note
            newAttachment.note = self.editedNote;
            [self.editedNote addAttachmentObject:newAttachment];
        }
    } else if(!self.idForTheNoteToBeEdited) {
        // It seems that we're created without a note, that will mean that we're required to create a new one.
        Note *newNote = [NSEntityDescription insertNewObjectForEntityForName:@"Note" inManagedObjectContext:self.noteEditorMOC];
        self.editedNote = newNote;
    } else { // Get a copy of edited note into the local context.
        NSError *error;
        self.editedNote = (Note *)[self.noteEditorMOC existingObjectWithID:self.idForTheNoteToBeEdited error:&error];
        NSAssert1(self.editedNote, @"Tragedy! Invalid ObjectID. Error: %@", [error description]);
    }
    [self refreshAttachments];
    [self refreshBooks];
}

- (IBAction)saveAndContinue:(id)sender
{
    DLog(@"This is IAMNoteWindowController's save.");
    // save (if useful) and pop back
    if([self.editedNote.title isEqualToString:@""] || [self.editedNote.text isEqualToString:@""]) {
        DLog(@"Save refused because no title ('%@')", self.editedNote.title);
        return;
    }
    // Save modified attachments (if any)
    [self saveModifiedAttachments];
    self.editedNote.timeStamp = [NSDate date];
    // Save book assignment (if any)
    NSUInteger selectedBookIndex = self.booksArrayController.selectionIndex;
    NSError *error;
    if (selectedBookIndex != 0) {
        Books *selectedBook = (Books *)[self.noteEditorMOC existingObjectWithID:self.booksArray[selectedBookIndex][@"objectID"] error:&error];
        DLog(@"Saving: selected book is: %@ (%lu)", selectedBook.name, (unsigned long)selectedBookIndex);
        if (selectedBook) {
            self.editedNote.book = selectedBook;
        } else {
            ALog(@"Error getting back the selected book: %@", [error description]);
        }
    }
    if(![self.noteEditorMOC save:&error])
        ALog(@"Unresolved error %@, %@", error, [error userInfo]);
    // Save on parent context
    [self.parentMOC performBlock:^{
        NSError *localError;
        if(![self.parentMOC save:&localError])
            ALog(@"Unresolved error saving parent context %@, %@", error, [error userInfo]);
    }];
}

- (IBAction)saveAndClose:(id)sender
{
    [self saveAndContinue:sender];
    [self.window performClose:sender];
}

- (IBAction)closeWithoutSave:(id)sender {
    [self.window performClose:sender];
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)refreshAttachments {
    NSMutableArray *tempArray = [[NSMutableArray alloc] initWithCapacity:[self.editedNote.attachment count]];
    for (Attachment *attach in self.editedNote.attachment) {
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFileType:attach.extension];
        NSDictionary *attachmentDictionary = @{@"attachment": attach, @"icon": icon};
        DLog(@"Added attachment to the collection: %@", attach.filename);
        [tempArray addObject:attachmentDictionary];
    }
    self.attachmentsArray = tempArray;
    CGFloat attachmentWindowHeight = 90.0;
    if([self.attachmentsArray count] == 0) {
        attachmentWindowHeight = 42.0;
    }
    self.attacmentContainerViewHeightConstraint.constant = attachmentWindowHeight;
    NSRect windowFrame = [self.attachmentContainerView frame];
    windowFrame.size.height = attachmentWindowHeight;
    [self.attachmentContainerView setFrame:windowFrame];
    [self.arrayController fetch:nil];
}

- (void)refreshBooks {
    NSUInteger currentBook = 0;
    NSDictionary *genericBook = @{@"name": @"No Book", @"objectID": [NSNull null]};
    NSMutableArray *tempArray = [[NSMutableArray alloc] initWithObjects:genericBook, nil];;
    // Set up the fetched results controller
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    // Edit the entity name as appropriate.
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"Books" inManagedObjectContext:self.noteEditorMOC];
    [fetchRequest setEntity:entity];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
    [fetchRequest setSortDescriptors:@[sortDescriptor]];
    NSError *error;
    NSArray *results = [self.noteEditorMOC executeFetchRequest:fetchRequest error:&error];
    if (!results) {
        NSLog(@"Error fetching bookList: %@", [error description]);
    } else {
        NSUInteger i = 1;
        for (Books *book in results) {
            if ([self.editedNote.book isEqual:book]) {
                currentBook = i;
            }
            i++;
            NSDictionary *newBook = @{@"name": book.name, @"objectID": book.objectID};
            [self.booksArrayController fetch:nil];
            [tempArray addObject:newBook];
        }
    }
    self.booksArray = [NSArray arrayWithArray:tempArray];
    self.booksArrayController.selectionIndex = currentBook;
}

- (BOOL) isAttachmentModified:(NSMutableDictionary *)openedFilesEntry {
    NSString *fullPath = [openedFilesEntry[@"fileURL"] path];
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:NULL];
    NSDate *fileModDate = [fileAttributes objectForKey:NSFileModificationDate];
    // Returns YES of the file has been modified after the creation
    return ([fileModDate compare:openedFilesEntry[@"timestamp"]] == NSOrderedDescending);
}

- (BOOL) isAnyAttachmentModified {
    BOOL retValue = NO;
    for (NSMutableDictionary *openedAttachEntry in self.openedFiles) {
        if([self isAttachmentModified:openedAttachEntry]) {
            retValue = YES;
            break;
        }
    }
    return retValue;
}

- (void)saveModifiedAttachments {
    for (NSMutableDictionary *openedAttachEntry in self.openedFiles) {
        if([self isAttachmentModified:openedAttachEntry]) {
            [self modifyAttachment:openedAttachEntry];
        }
    }
}

- (void)modifyAttachment:(NSMutableDictionary *)openedFilesEntry {
    // find the modified attachment
    NSURL *url = openedFilesEntry[@"fileURL"];
    BOOL found = NO;
    NSString *attachmentName = [[url path] lastPathComponent];
    for (Attachment *attach in self.editedNote.attachment) {
        if([attach.filename isEqualToString:attachmentName]) {
            // Found! Now modify the attachment values.
            attach.data = [NSData dataWithContentsOfURL:url];
            attach.timeStamp = openedFilesEntry[@"timestamp"] = [NSDate date];
            found = YES;
            break;
        }
    }
    if(!found) {
        ALog(@"Attachment to be modified %@ not found in attachment list. This can happen only if it has been deleted from the attachments.", url);
    }
}

// This would be for an openWith menu. not implemented
- (IBAction)openAttachmentWith:(id)sender {
    if([[self.arrayController selectedObjects] count] != 0) {
        Attachment *toBeShown = [self.arrayController selectedObjects][0][@"attachment"];
        NSURL *pathToBeShown = [toBeShown generateFileInCacheDirectory];
        DLog(@"Open with apps requested for attachment: %@", pathToBeShown);
        CFURLRef defaultHandler;
        LSGetApplicationForURL((__bridge CFURLRef)(pathToBeShown), kLSRolesAll, NULL, &defaultHandler);
        CFArrayRef availableAppsUrls = LSCopyApplicationURLsForURL((__bridge CFURLRef)(pathToBeShown), kLSRolesAll);
        self.appsInfo = [[NSMutableArray alloc] initWithCapacity:[(__bridge NSArray *) availableAppsUrls count]];
        for (NSURL *url in (__bridge NSArray *)availableAppsUrls) {
            CFStringRef appName;
            LSCopyDisplayNameForURL((__bridge CFURLRef)(url), &appName);
            NSImage *appIcon = [[NSWorkspace sharedWorkspace] iconForFile:[url path]];
            [self.appsInfo addObject:@{@"appName":(__bridge NSString *)appName, @"appIcon":appIcon, @"appURL":url}];
            CFRelease(appName);
        }
        CFRelease(availableAppsUrls);
        // Now set the default app at position 0
        for (int i = 1; i < [self.appsInfo count]; i++) {
            if([(__bridge NSURL *)defaultHandler isEqualTo:self.appsInfo[i][@"appURL"]]) {
                [self.appsInfo exchangeObjectAtIndex:0 withObjectAtIndex:i];
                break;
            }
        }
        CFRelease(defaultHandler);
        if(!self.openWithController) {
            self.openWithController = [[IAMOpenWithWC alloc] initWithWindowNibName:@"IAMOpenWithWC"];
        }
        self.openWithController.appArray = self.appsInfo;
        [[NSApplication sharedApplication] beginSheet:self.openWithController.window modalForWindow:self.window modalDelegate:self didEndSelector:@selector(didEndSheet:returnCode:contextInfo:) contextInfo:nil];
    }
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
    [self.openWithController.window orderOut:self];
    if (self.openWithController.selectedAppId == NSNotFound) {
        DLog(@"User cancelled open with action");
    } else {
        DLog(@"Open attachment with %@ (@ %@)", self.appsInfo[self.openWithController.selectedAppId][@"appName"], self.appsInfo[self.openWithController.selectedAppId][@"appURL"]);
        Attachment *toBeOpened = [self.arrayController selectedObjects][0][@"attachment"];
        NSURL *file = [toBeOpened generateFileInCacheDirectory];
        if(![[NSWorkspace sharedWorkspace] openFile:[file path] withApplication:[self.appsInfo[self.openWithController.selectedAppId][@"appURL"] path]]) {
            NSAlert *alert = [[NSAlert alloc] init];
            NSString *message = [NSString stringWithFormat:@"No application is able to open the file \"%@\"", toBeOpened.filename];
            [alert setInformativeText:message];
            [alert setMessageText:NSLocalizedString(@"Warning", @"")];
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:self.window modalDelegate:nil didEndSelector:nil contextInfo:nil];
        }  else {
            [self mapOpenedAttachment:file];
        }
    }
    self.openWithController = nil;
}

- (IBAction)showAttachmentInFinder:(id)sender {
    if([[self.arrayController selectedObjects] count] != 0) {
        Attachment *toBeShown = [self.arrayController selectedObjects][0][@"attachment"];
        NSURL *pathToBeShown = [toBeShown generateFileInCacheDirectory];
        DLog(@"Show in finder requested for attachment: %@", pathToBeShown);
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[pathToBeShown]];
    }
}

- (void)attachAttachment:(NSURL *)url {
    // Check if it is a normal file
    NSError *err;
    NSFileWrapper *fw = [[NSFileWrapper alloc] initWithURL:url options:NSFileWrapperReadingImmediate error:&err];
    if(!fw) {
        NSLog(@"Error creating file wrapper for %@: %@", url, [err description]);
        return;
    }
    if(![fw isRegularFile]) {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *message = [NSString stringWithFormat:@"The file at \"%@\" is not a \"regular\" file and cannot currently be attached to a note. Sorry for that. You can try to compress it and attach the compresssed file to the note", [url path]];
        [alert setInformativeText:message];
        [alert setMessageText:NSLocalizedString(@"Warning", @"")];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window modalDelegate:nil didEndSelector:nil contextInfo:nil];
        return;
    }
    Attachment *newAttachment = [NSEntityDescription insertNewObjectForEntityForName:@"Attachment" inManagedObjectContext:self.noteEditorMOC];
    
    CFStringRef fileExtension = (__bridge CFStringRef) [url pathExtension];
    CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension, NULL);
    DLog(@"FileUTI is: %@", fileUTI);
    if (UTTypeConformsTo(fileUTI, kUTTypeImage))
        newAttachment.type = @"Image";
    else if (UTTypeConformsTo(fileUTI, kUTTypeMovie))
        newAttachment.type = @"Movie";
    else if (UTTypeConformsTo(fileUTI, kUTTypeAudio))
        newAttachment.type = @"Audio";
    else if (UTTypeConformsTo(fileUTI, kUTTypeText))
        newAttachment.type = @"Text";
    else if (UTTypeConformsTo(fileUTI, kUTTypeFileURL))
        newAttachment.type = @"Link";
    else if (UTTypeConformsTo(fileUTI, kUTTypeURL))
        newAttachment.type = @"Link";
    else
        newAttachment.type = @"Other";
    newAttachment.uti = (__bridge NSString *)(fileUTI);
    CFRelease(fileUTI);
    newAttachment.extension = [url pathExtension];
    newAttachment.filename = [url lastPathComponent];
    newAttachment.data = [fw regularFileContents];
    // Now link attachment to the note
    newAttachment.note = self.editedNote;
    DLog(@"Adding attachment: %@", newAttachment);
    [self.editedNote addAttachmentObject:newAttachment];
    [self saveAndContinue:nil];
    [self refreshAttachments];
}

- (IBAction)deleteAttachment:(id)sender {
    if([[self.arrayController selectedObjects] count] != 0) {
        DLog(@"Delete requested for attachment: %@", [self.arrayController selectedObjects][0]);
        Attachment *toBeDeleted = [self.arrayController selectedObjects][0][@"attachment"];
        [self.arrayController removeSelectedObjects:[self.arrayController selectedObjects]];
        [self.editedNote removeAttachmentObject:toBeDeleted];
        [self saveAndContinue:nil];
        [self refreshAttachments];
    }
}

- (IBAction)previewMarkdown:(id)sender {
    [self loadMarkdownPreview];
    [self.previewWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)addAttachment:(id)sender {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowsMultipleSelection = NO;
    openPanel.canChooseDirectories = NO;
    openPanel.canChooseFiles = YES;
    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result){
        if(result == NSFileHandlingPanelCancelButton) {
            DLog(@"User canceled");
        } else {
            DLog(@"User selected URL %@, now saving.", openPanel.URL);
            [self attachAttachment:openPanel.URL];
        }
    }];
}

- (void)mapOpenedAttachment:(NSURL *)file {
    // Map the opened file to check for modifications after
    if(!self.openedFiles) {
        self.openedFiles = [[NSMutableArray alloc] initWithCapacity:1];
    }
    NSMutableDictionary *newOpenedFileEntry = [[NSMutableDictionary alloc] initWithDictionary:@{@"fileURL": file, @"timestamp": [NSDate date]}];
    [self.openedFiles addObject:newOpenedFileEntry];
}

// This event comes from the collection item view subclass
- (IBAction)collectionItemViewDoubleClick:(id)sender {
    if([[self.arrayController selectedObjects] count] != 0) {
        DLog(@"Double click detected in collection view, processing event.");
        DLog(@"Selected object array: %@", [self.arrayController selectedObjects]);
        Attachment *toBeOpened = [self.arrayController selectedObjects][0][@"attachment"];
        NSURL *file = [toBeOpened generateFileInCacheDirectory];
        if(![[NSWorkspace sharedWorkspace] openURL:file]) {
            NSAlert *alert = [[NSAlert alloc] init];
            NSString *message = [NSString stringWithFormat:@"No application is able to open the file \"%@\"", toBeOpened.filename];
            [alert setInformativeText:message];
            [alert setMessageText:NSLocalizedString(@"Warning", @"")];
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:self.window modalDelegate:nil didEndSelector:nil contextInfo:nil];
        }  else {
            [self mapOpenedAttachment:file];
        }
    } else {
        NSLog(@"Double click detected in collection view, but no collection item is selected. This should not happen");
    }
}

#pragma mark - Publishing

- (IBAction)publish:(id)sender {
    DLog(@"Text:\n%@\n<end>", self.editedNote.text);
}

- (IBAction)exportHTML:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setCanCreateDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setNameFieldLabel:@"Export HTML To"];
    [panel setPrompt:@"Export"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger result) {
        NSURL* url = [panel URL];
        NSURL *outURL = [url URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.html", self.editedNote.title]];
        DLog(@"User selected URL %@, now we should export to it (%@).", url, outURL);
        NSError *error;
        if (![self.editedNote exportAsHTMLToURL:outURL error:&error]) {
            ALog(@"Error exporting file: %@", error);
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert runModal];
        }
    }];
}

- (IBAction)exportMarkdownForPelican:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setCanCreateDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setNameFieldLabel:@"Export Markdown To"];
    [panel setPrompt:@"Export"];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger result) {
        NSURL* url = [panel URL];
        DLog(@"User selected URL %@, now we should export to it.", url);
        NSError *error;
        if (![self.editedNote exportAsMarkdownForPelican:url error:&error]) {
            ALog(@"Error exporting markdown: %@", error);
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert runModal];
        }
    }];
}


#pragma mark - markdown support

- (void)textDidChange:(NSNotification *)notification {
    // Text is changed in textview, generate markdown and show it (only if preview windows is visible)
    if ([self.previewWindow isVisible]) {
        [self loadMarkdownPreview];
    }
}

- (void)loadMarkdownPreview {
    NSError *error;
    [self.previewWindow setTitle:self.editedNote.title];
    if (![self.editedNote exportAsHTMLToURL:self.cacheFile error:&error]) {
        ALog(@"Error saving html preview file: %@", error);
    } else {
        [self.previewWebView.mainFrame loadRequest:[NSURLRequest requestWithURL:self.cacheFile]];
    }
    [self.previewWebView.mainFrame loadRequest:[NSURLRequest requestWithURL:self.cacheFile]];
}

#pragma mark - WebUIDelegate

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems {
    // Allow only selected actions
    NSMutableArray *returnedMenuItems = [[NSMutableArray alloc] initWithCapacity:[defaultMenuItems count]];
    for (NSMenuItem *menuItem in defaultMenuItems) {
        switch (menuItem.tag) {
            case 2000: // This is openlink
            case WebMenuItemTagCopyLinkToClipboard:
            case WebMenuItemTagCopyImageToClipboard:
            case WebMenuItemTagCopy:
            case WebMenuItemTagSpellingGuess:
            case WebMenuItemTagNoGuessesFound:
            case WebMenuItemTagIgnoreSpelling:
            case WebMenuItemTagLearnSpelling:
            case WebMenuItemTagOther:
            case WebMenuItemTagSearchInSpotlight:
            case WebMenuItemTagSearchWeb:
            case WebMenuItemTagLookUpInDictionary:
            case WebMenuItemTagOpenWithDefaultApplication:
                [returnedMenuItems addObject:menuItem];
                break;
            default:
                break;
        }
    }
    return returnedMenuItems;
}

#pragma mark - WebPolicyDelegate

- (void)webView:(WebView *)webView decidePolicyForNavigationAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id < WebPolicyDecisionListener >)listener {
    // Redirect links to external browser if is a link or "other" with a real (not "file:") url
    if (([actionInformation[WebActionNavigationTypeKey] intValue] == WebNavigationTypeLinkClicked) ||
        ([actionInformation[WebActionNavigationTypeKey] intValue] == WebNavigationTypeOther &&
         ![actionInformation[WebActionOriginalURLKey] isFileURL])) {
        [[NSWorkspace sharedWorkspace] openURL:actionInformation[WebActionOriginalURLKey]];
        [listener ignore];
    } else {
        [listener use];
    }
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification
{
    // Notify delegate that we're closing ourselves
    DLog(@"Notifying delegate.");
    if(self.delegate)
        [self.delegate IAMNoteEditorWCDidCloseWindow:self];
}

- (BOOL)windowShouldClose:(id)window {
    if (_userConsentedToClose) {
        // User has already gone through save sheet and choosen to close the window
        _userConsentedToClose = NO; // Reset value just in case
        return YES;
    }
    if ([self.noteEditorMOC hasChanges] || [self isAnyAttachmentModified]) {
        NSAlert *saveAlert = [[NSAlert alloc] init];
        [saveAlert addButtonWithTitle:@"Save"];
        [saveAlert addButtonWithTitle:@"Cancel"];
        [saveAlert addButtonWithTitle:@"Don't Save"];
        [saveAlert setMessageText:@"Save changes to note?"];
        [saveAlert setInformativeText:@"If you don't save the changes, they will be lost"];
        [saveAlert beginSheetModalForWindow:window
                              modalDelegate:self
                             didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                                contextInfo:nil];
        return NO;
    }
    // note haven't been changed.
    return YES;
}

// This is the method that gets called when a user selected a choice from the
// do you want to save preferences sheet.
- (void)alertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    [[alert window] orderOut:self];
    switch (returnCode) {
        case NSAlertFirstButtonReturn:
            // Save button
            [self saveAndContinue:self];
            _userConsentedToClose = YES;
            [[self window] performClose:self];
            break;
        case NSAlertSecondButtonReturn:
            // Cancel button
            // Do nothing
            break;
        case NSAlertThirdButtonReturn:
            // Don't Save button
            _userConsentedToClose = YES;
            [[self window] performClose:self];
            break;
        default:
            NSAssert1(NO, @"Unknown button return: %i", returnCode);
            break;
    }
}

#pragma mark - NSCollectionViewDelegate

- (NSDragOperation)collectionView:(NSCollectionView *)collectionView validateDrop:(id < NSDraggingInfo >)draggingInfo proposedIndex:(NSInteger *)proposedDropIndex dropOperation:(NSCollectionViewDropOperation *)proposedDropOperation {
    NSPasteboard *pboard;
    NSDragOperation sourceDragMask;
    
    sourceDragMask = [draggingInfo draggingSourceOperationMask];
    pboard = [draggingInfo draggingPasteboard];
    NSDragOperation retValue = NSDragOperationNone;
    if ([[pboard types] containsObject:NSFilenamesPboardType]) {
        if (sourceDragMask & NSDragOperationCopy) {
            retValue = NSDragOperationCopy;
            // Set drop after the last element
        }
    }
    DLog(@"Dragging entered %@ position %ld for %@ (retvalue: %ld)", (*proposedDropOperation == 0) ? @"on" : @"before", (long)*proposedDropIndex , [pboard types][0], retValue);
    return retValue;
}

- (BOOL)collectionView:(NSCollectionView *)collectionView acceptDrop:(id < NSDraggingInfo >)draggingInfo index:(NSInteger)index dropOperation:(NSCollectionViewDropOperation)dropOperation {
    NSPasteboard *pboard;
    NSDragOperation sourceDragMask;
    
    sourceDragMask = [draggingInfo draggingSourceOperationMask];
    pboard = [draggingInfo draggingPasteboard];
    DLog(@"Should perform drag on %@", [pboard types]);
    
    if ( [[pboard types] containsObject:NSFilenamesPboardType] ) {
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        DLog(@"Files to be copied: %@", files);
        // Send file(s) to delegate for processing
        for (NSString *fileName in files) {
            NSURL *url = [[NSURL alloc] initFileURLWithPath:fileName];
            DLog(@"User dropped URL %@, now saving.", url);
            [self attachAttachment:url];
        }
    }

    return YES;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    switch(context) {
        case NSDraggingContextOutsideApplication:
            DLog(@"Called for outside drag.");
            return NSDragOperationCopy;
            break;
            
        case NSDraggingContextWithinApplication:
        default:
            DLog(@"Called for drag inside the application.");
            return NSDragOperationNone;
            break;
    }
}

- (BOOL)collectionView:(NSCollectionView *)collectionView writeItemsAtIndexes:(NSIndexSet *)indexes toPasteboard:(NSPasteboard *)pasteboard {
    Attachment *toBeDragged = [self.arrayController arrangedObjects][indexes.firstIndex][@"attachment"];
    DLog(@"Writing %@ to pasteboard for dragging.", toBeDragged);
    NSURL *file = [toBeDragged generateFileInCacheDirectory];
    if(file) {
        [pasteboard clearContents];
        return [pasteboard writeObjects:@[file]];
    }
    return NO;
}

@end

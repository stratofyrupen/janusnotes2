//
//  Attachment.m
//  I Am Mine
//
//  Created by Giacomo Tufano on 04/03/13.
//
//  Copyright (c)2013, Giacomo Tufano (gt@ilTofa.com)
//  Licensed under MIT license. See LICENSE file or http://www.opensource.org/licenses/mit-license.php
//

#import "Attachment.h"
#import "Note.h"

#if TARGET_OS_IPHONE
#import <MobileCoreServices/MobileCoreServices.h>
#else
#import <Cocoa/Cocoa.h>
#endif

@implementation Attachment

@dynamic type;
@dynamic primitiveType;
@dynamic uuid;
@dynamic data;
@dynamic creationDate;
@dynamic uti;
@dynamic primitiveUti;
@dynamic extension;
@dynamic primitiveExtension;
@dynamic filename;
@dynamic primitiveFilename;
@dynamic note;
@dynamic timeStamp;

#pragma mark - awakeFromInsert: setup initial values

- (void) awakeFromInsert
{
    [super awakeFromInsert];
    [self setUuid:[[NSUUID UUID] UUIDString]];
    [self setCreationDate:[NSDate date]];
    [self setTimeStamp:[NSDate date]];
}

#pragma mark - Transient properties

- (NSString *)type
{
    // Create and cache the section identifier on demand.
    [self willAccessValueForKey:@"type"];
    NSString *tmp = [self primitiveType];
    [self didAccessValueForKey:@"type"];
    if (!tmp) {
        CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)(self.extension), NULL);
        if (UTTypeConformsTo(fileUTI, kUTTypeImage))
            tmp = @"Image";
        else if (UTTypeConformsTo(fileUTI, kUTTypeMovie))
            tmp = @"Movie";
        else if (UTTypeConformsTo(fileUTI, kUTTypeAudio))
            tmp = @"Audio";
        else if (UTTypeConformsTo(fileUTI, kUTTypeText))
            tmp = @"Text";
        else if (UTTypeConformsTo(fileUTI, kUTTypeFileURL))
            tmp = @"Link";
        else if (UTTypeConformsTo(fileUTI, kUTTypeURL))
            tmp = @"Link";
        else if([self.extension isEqualToString:@"url"])
            tmp = @"Link";
        else
            tmp = @"Other";
        if(fileUTI)
            CFRelease(fileUTI);
        [self setPrimitiveType:tmp];
    }
    return tmp;
}

- (NSString *)uti
{
    // Create and cache the section identifier on demand.
    [self willAccessValueForKey:@"uti"];
    NSString *tmp = [self primitiveUti];
    [self didAccessValueForKey:@"uti"];
    if (!tmp) {
        CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)(self.extension), NULL);
        tmp = (__bridge NSString *)(fileUTI);
        [self setPrimitiveUti:tmp];
        CFRelease(fileUTI);
    }
    return tmp;
}

#pragma mark - Filename setter

// if filename or extension changes, type and uti become invalid
- (void)setFilename:(NSString *)filename {
    [self willChangeValueForKey:@"filename"];
    [self setPrimitiveFilename:filename];
    [self didChangeValueForKey:@"filename"];
    [self setPrimitiveType:nil];
    [self setPrimitiveUti:nil];
}

- (void)setExtension:(NSString *)extension {
    [self willChangeValueForKey:@"extension"];
    [self setPrimitiveExtension:extension];
    [self didChangeValueForKey:@"extension"];
    [self setPrimitiveType:nil];
    [self setPrimitiveUti:nil];
}

#pragma mark - write out

- (NSURL *)generateFileInCacheDirectory {
    NSError *error;
    NSURL *cacheDirectory = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    NSURL *cacheFile;
    if(self.filename && ![self.filename isEqualToString:@""])
        cacheFile = [cacheDirectory URLByAppendingPathComponent:self.filename];
    else {
        NSString *tempUuid = [[NSUUID UUID] UUIDString];
        NSString *temporaryFilename = [NSString stringWithFormat:@"%@.%@", tempUuid, self.extension];
        cacheFile = [cacheDirectory URLByAppendingPathComponent:temporaryFilename];
    }
    DLog(@"Filename will be: %@", cacheFile);
    if(![self.data writeToURL:cacheFile options:0 error:&error])
        NSLog(@"Error %@ writing attachment data to temporary file %@\nData: %@.", [error description], cacheFile, self);
    return cacheFile;
}

- (BOOL)generateFileToDirectory:(NSURL *)exportDirectory error:(NSError **)error {
    NSURL *cacheFile;
    if (!self.filename || [self.filename isEqualToString:@""]) {
        NSString *tempUuid = [[NSUUID UUID] UUIDString];
        self.filename = [NSString stringWithFormat:@"%@.%@", tempUuid, self.extension];
    }
    cacheFile = [exportDirectory URLByAppendingPathComponent:self.filename];
    DLog(@"Filename will be: %@", cacheFile);
    BOOL retValue = [self.data writeToURL:cacheFile options:0 error:error];
    if(!retValue) {
        ALog(@"Error %@ writing attachment data to temporary file %@\nData: %@.", [*error description], cacheFile, self);
    }
    return retValue;
}

@end

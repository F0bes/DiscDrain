//
//  IOKitManager.h
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import <Foundation/Foundation.h>
#import "DiscInstance.h"

@interface IOKitManager : NSObject
+ (NSArray<DiscInstance*>*)listDiscs;
+ (NSString*)discNameForDiscInstance:(DiscInstance*)bsdName;
+ (void)ripDisc:(DiscInstance*)disc
		  toPath:(NSString*)isoPath
		cuePath:(NSString*)cuePath
		progress:(void (^)(double fraction))progressBlock
	shouldCancel:(BOOL (^)(void))shouldCancel
	  completion:(void (^)(NSError* error))completionBlock;
+ (void)getDiscCue:(DiscInstance*)disc
			toPath:(NSString*)cuePath;
+ (void)getMD5Sum:(NSString*)filePath
	   completion:(void (^)(NSError* error, NSString* md5sum))completionBlock;
+ (void)getSHA256Sum:(NSString*)filePath
		  completion:(void (^)(NSError* error, NSString* md5sum))completionBlock;

+ (void)ejectDiskAtBSDPath:(NSString*)bsdPath completion:(void (^)(BOOL success, NSError* error))completion;
+ (BOOL)unmountDiskAtBSDPath:(NSString*)bsdPath;
+ (BOOL)isDiskMountedAtBSDPath:(NSString*)bsdPath;
@end

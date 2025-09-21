//
//  IOKitManager.m
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import "IOKitManager.h"
#import <DiskArbitration/DiskArbitration.h>
#import <CommonCrypto/CommonCrypto.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOMedia.h>
#import <IOKit/storage/IOCDMedia.h>
#import <IOKit/storage/IOCDMediaBSDClient.h>
#import <IOKit/storage/IOCDTypes.h>
#import <IOKit/storage/IODVDMedia.h>
#import <IOKit/scsi/SCSITaskLib.h>
#include <sys/disk.h>


@implementation IOKitManager

+ (NSArray<DiscInstance*>*)listDiscs
{
	NSMutableArray<DiscInstance*>* result = [NSMutableArray array];

	// DVD drives
	CFMutableDictionaryRef dvdMatch = IOServiceMatching(kIODVDMediaClass);
	if (dvdMatch)
	{
		NSArray<DiscInstance*>* dvds = [self iterateServices:dvdMatch type:DiscTypeDVD];
		[result addObjectsFromArray:dvds];
	}

	// CD drives
	CFMutableDictionaryRef cdMatch = IOServiceMatching(kIOCDMediaClass);
	if (cdMatch)
	{
		NSArray<DiscInstance*>* cds = [self iterateServices:cdMatch type:DiscTypeCD];
		[result addObjectsFromArray:cds];
	}

	return result;
}


+ (NSArray<DiscInstance*>*)iterateServices:(CFMutableDictionaryRef)match type:(DiscType)type
{
	NSMutableArray<DiscInstance*>* result = [NSMutableArray array];

	CFDictionarySetValue(match, CFSTR(kIOMediaWholeKey), kCFBooleanTrue);

	io_iterator_t iter;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS)
	{
		io_object_t service;
		while ((service = IOIteratorNext(iter)))
		{
			CFStringRef bsdName = IORegistryEntryCreateCFProperty(
				service,
				CFSTR(kIOBSDNameKey),
				kCFAllocatorDefault,
				0);

			if (bsdName)
			{
				char cstr[PATH_MAX];
				if (CFStringGetCString(bsdName, cstr, sizeof(cstr), kCFStringEncodingUTF8))
				{
					DiscInstance* disc = [[DiscInstance alloc] initWithType:type
																	   path:[NSString stringWithFormat:@"/dev/%s", cstr]
																	  rpath:[NSString stringWithFormat:@"/dev/r%s", cstr]];
					[result addObject:disc];
				}
				CFRelease(bsdName);
			}

			IOObjectRelease(service);
		}
		IOObjectRelease(iter);
	}

	return result;
}

+ (NSString*)discNameForDiscInstance:(DiscInstance*)discInstance
{
	DASessionRef session = DASessionCreate(kCFAllocatorDefault);
	if (!session)
		return nil;

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [discInstance.bsdPath UTF8String]);
	if (!disk)
	{
		CFRelease(session);
		return nil;
	}

	CFDictionaryRef desc = DADiskCopyDescription(disk);
	NSString* volumeName = nil;
	if (desc)
	{
		volumeName = CFDictionaryGetValue(desc, kDADiskDescriptionVolumeNameKey);
		if (volumeName)
			volumeName = [volumeName copy];
		CFRelease(desc);
	}

	CFRelease(disk);
	CFRelease(session);

	return volumeName;
}

static BOOL DDGetDeviceSize(NSString* bsdPath, uint32_t* outBlockSize, uint64_t* outBlockCount)
{
	int fd = open(bsdPath.fileSystemRepresentation, O_RDONLY);
	if (fd < 0)
		return NO;

	uint32_t bs = 0;
	uint64_t bc = 0;

	BOOL ok = YES;
	if (ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == -1)
		ok = NO;
	if (ok && ioctl(fd, DKIOCGETBLOCKCOUNT, &bc) == -1)
		ok = NO;

	close(fd);
	if (!ok)
		return NO;

	if (outBlockSize)
		*outBlockSize = bs;
	if (outBlockCount)
		*outBlockCount = bc;
	return YES;
}

unsigned long long GetDiscSize(NSString* bsdPath)
{
	uint32_t bs = 0;
	uint64_t bc = 0;
	if (!DDGetDeviceSize(bsdPath, &bs, &bc))
		return 0;
	return (unsigned long long)bs * (unsigned long long)bc;
}

uint32_t readLeadoutLBA(int inFd, NSError **err) {
	const size_t tocBufSize = 4096;
	void *tocBuffer = calloc(1, tocBufSize);
	if (!tocBuffer) {
		if (err) *err = [NSError errorWithDomain:@"DiscDrain" code:4
										 userInfo:@{NSLocalizedDescriptionKey : @"Unable to alloc TOC buffer"}];
		return 0;
	}

	dk_cd_read_toc_t toc = {};
	toc.format = kCDTOCFormatTOC;
	toc.formatAsTime = true;
	toc.buffer = tocBuffer;
	toc.bufferLength = tocBufSize;

	uint32_t leadoutLBA = 0;
	if (ioctl(inFd, DKIOCCDREADTOC, &toc) < 0) {
		if (err) *err = [NSError errorWithDomain:@"DiscDrain" code:errno
										 userInfo:@{NSLocalizedDescriptionKey :
													[NSString stringWithFormat:@"TOC read failed: %s", strerror(errno)]}];
		free(tocBuffer);
		return 0;
	}

	CDTOC *cdtoc = (CDTOC *)tocBuffer;
	uint32_t descCount = CDTOCGetDescriptorCount(cdtoc);
	for (uint32_t i = 0; i < descCount; i++) {
		CDTOCDescriptor desc = cdtoc->descriptors[i];
		if (desc.point == 0xA2) { // lead-out
			leadoutLBA = (desc.p.minute * 60 + desc.p.second) * 75 + desc.p.frame - 150;
			break;
		}
	}

	free(tocBuffer);
	return leadoutLBA;
}

BOOL writeCUEFile(NSString *cuePath, NSString *isoFileName, int inFd, NSError **err) {
	const size_t tocBufSize = 4096;
	void *tocBuffer = calloc(1, tocBufSize);
	if (!tocBuffer) {
		if (err) *err = [NSError errorWithDomain:@"DiscDrain" code:4
										 userInfo:@{NSLocalizedDescriptionKey : @"Unable to alloc TOC buffer"}];
		return NO;
	}

	dk_cd_read_toc_t toc = {};
	toc.format = kCDTOCFormatTOC;
	toc.formatAsTime = true;
	toc.buffer = tocBuffer;
	toc.bufferLength = tocBufSize;

	if (ioctl(inFd, DKIOCCDREADTOC, &toc) < 0) {
		if (err) *err = [NSError errorWithDomain:@"DiscDrain" code:errno
										 userInfo:@{NSLocalizedDescriptionKey :
													[NSString stringWithFormat:@"TOC read failed: %s", strerror(errno)]}];
		free(tocBuffer);
		return NO;
	}

	CDTOC *cdtoc = (CDTOC *)tocBuffer;
	uint32_t descCount = CDTOCGetDescriptorCount(cdtoc);

	// Find first track LBA
	uint32_t firstTrackLBA = 0;
	for (uint32_t i = 0; i < descCount; i++) {
		CDTOCDescriptor desc = cdtoc->descriptors[i];
		if (desc.point >= 1 && desc.point <= 99) {
			firstTrackLBA = (desc.p.minute * 60 + desc.p.second) * 75 + desc.p.frame - 150;
			break;
		}
	}

	NSMutableString *cue = [NSMutableString string];
	[cue appendFormat:@"FILE \"%@\" BINARY\n", isoFileName.lastPathComponent];

	for (uint32_t i = 0; i < descCount; i++) {
		CDTOCDescriptor desc = cdtoc->descriptors[i];
		if (desc.point == 0xA0 || desc.point == 0xA1 || desc.point == 0xA2) continue;

		int trackNum = desc.point;
		BOOL isData = (desc.control & 0x04) != 0;
		const char *trackType = isData ? "MODE2/2352" : "AUDIO";

		uint32_t trackLBA = (desc.p.minute * 60 + desc.p.second) * 75 + desc.p.frame - 150;
		uint32_t relLBA = trackLBA - firstTrackLBA;
		uint32_t m = relLBA / 75 / 60;
		uint32_t s = (relLBA / 75) % 60;
		uint32_t f = relLBA % 75;

		[cue appendFormat:@"  TRACK %02d %s\n", trackNum, trackType];
		[cue appendFormat:@"    INDEX 01 %02d:%02d:%02d\n", m, s, f];
	}

	NSError *writeErr = nil;
	BOOL success = [cue writeToFile:cuePath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
	if (!success && err) *err = writeErr;

	free(tocBuffer);
	return success;
}


+ (void)ripDisc:(DiscInstance*)disc
		toPath:(NSString*)isoPath
		cuePath:(NSString*)cuePath
	   progress:(void (^)(double fraction))progressBlock
   shouldCancel:(BOOL (^)(void))shouldCancel
	 completion:(void (^)(NSError* error))completionBlock
{
	BOOL isCD = (disc.type == DiscTypeCD);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

		const char* inPath = disc.rbsdPath.fileSystemRepresentation;
		const char* outPath = isoPath.fileSystemRepresentation;

		int inFd = open(inPath, O_RDONLY);
		if (inFd < 0) {
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock([NSError errorWithDomain:NSPOSIXErrorDomain code:errno
												userInfo:@{NSLocalizedDescriptionKey :
															   [NSString stringWithFormat:@"open(%@) failed: %s",
																disc.bsdPath, strerror(errno)]}]);
			});
			return;
		}

		int outFd = open(outPath, O_CREAT | O_WRONLY | O_TRUNC, 0666);
		if (outFd < 0) {
			int saved = errno;
			close(inFd);
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock([NSError errorWithDomain:NSPOSIXErrorDomain code:saved
												userInfo:@{NSLocalizedDescriptionKey :
															   [NSString stringWithFormat:@"create(%@) failed: %s",
																isoPath, strerror(saved)]}]);
			});
			return;
		}

		(void)fcntl(inFd, F_NOCACHE, 1);
		(void)fcntl(outFd, F_NOCACHE, 1);

		unsigned long long totalSize = 0;
		for(int attempt = 1; attempt <= 5; attempt++)
		{
			totalSize = GetDiscSize(disc.bsdPath ?: disc.rbsdPath);
			if(totalSize > 0)
				break;
			usleep(200000);
		}

		if(totalSize == 0)
		{
			close(inFd); close(outFd);
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock([NSError errorWithDomain:@"DiscDrain" code:3
												userInfo:@{NSLocalizedDescriptionKey : @"Failed to get disc size (reported 0 bytes after 5 attempts)"}]);
			});
			return;
		}

		void *buffer = malloc(4 * 1024 * 1024); // 4 MiB
		if (!buffer) {
			close(inFd); close(outFd);
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock([NSError errorWithDomain:@"DiscDrain" code:3
												userInfo:@{NSLocalizedDescriptionKey : @"Failed to allocate I/O buffer"}]);
			});
			return;
		}

		BOOL ok = YES;
		NSError *err = nil;

		if (isCD) {
			uint32_t leadoutLBA = readLeadoutLBA(inFd, &err);
			if (leadoutLBA == 0) {
				ok = NO;
				if (!err) err = [NSError errorWithDomain:@"DiscDrain" code:3
												userInfo:@{NSLocalizedDescriptionKey : @"Failed to read lead-out LBA"}];
			}

			const size_t RAW_SECTOR = kCDSectorSizeWhole;
			const size_t sectorsPerChunk = 30;
			void *rawBuf = malloc(RAW_SECTOR * sectorsPerChunk);
			if (!rawBuf) {
				ok = NO;
				err = [NSError errorWithDomain:@"DiscDrain" code:3
									   userInfo:@{NSLocalizedDescriptionKey : @"Failed to allocate raw CD buffer"}];
			}

			unsigned long long lba = 0;
			while (ok && lba < leadoutLBA) {
				if (shouldCancel && shouldCancel()) {
					ok = NO;
					err = [NSError errorWithDomain:@"DiscDrain" code:-999
										   userInfo:@{NSLocalizedDescriptionKey : @"Cancelled"}];
					break;
				}

				size_t toReadSectors = MIN(sectorsPerChunk, leadoutLBA - lba);
				size_t toReadBytes = toReadSectors * RAW_SECTOR;

				dk_cd_read_t cdread = {};
				cdread.offset = lba * RAW_SECTOR;
				cdread.sectorArea = kCDSectorAreaSync | kCDSectorAreaHeader | kCDSectorAreaSubHeader |
									kCDSectorAreaUser | kCDSectorAreaAuxiliary;
				cdread.sectorType = kCDSectorTypeUnknown;
				cdread.buffer = rawBuf;
				cdread.bufferLength = (uint32_t)toReadBytes;

				if (ioctl(inFd, DKIOCCDREAD, &cdread) < 0) {
					if (errno != EINTR) {
						ok = NO;
						err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
											   userInfo:@{NSLocalizedDescriptionKey :
															  [NSString stringWithFormat:@"DKIOCCDREAD failed at LBA %llu: %s",
															   lba, strerror(errno)]}];
						break;
					}
					continue; // retry on EINTR
				}

				size_t written = 0;
				while (written < cdread.bufferLength) {
					ssize_t w = write(outFd, (char*)rawBuf + written, cdread.bufferLength - written);
					if (w < 0) {
						if (errno != EINTR) {
							ok = NO;
							err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
												   userInfo:@{NSLocalizedDescriptionKey :
																  [NSString stringWithFormat:@"Write failed at raw LBA %llu: %s",
																   lba, strerror(errno)]}];
							break;
						}
						continue; // retry on EINTR
					}
					written += w;
				}
				if (!ok) break;

				lba += toReadSectors;
				if (progressBlock) {
					double fraction = (double)lba / (double)leadoutLBA;
					dispatch_async(dispatch_get_main_queue(), ^{ progressBlock(fraction); });
				}
			}

			free(rawBuf);

		} else { // DVD
			unsigned long long copied = 0;
			const size_t bufferSize = 4 * 1024 * 1024; // 4 MiB
			int consecutiveIOErrors = 0;
			const int maxConsecutiveIOErrors = 50;

			while (ok && copied < totalSize) {
				if (shouldCancel && shouldCancel()) {
					ok = NO;
					err = [NSError errorWithDomain:@"DiscDrain" code:-999
										   userInfo:@{NSLocalizedDescriptionKey : @"Cancelled"}];
					break;
				}

				size_t toRead = MIN((unsigned long long)bufferSize, totalSize - copied);
				ssize_t n = read(inFd, buffer, toRead);

				if (n < 0) {
					if (errno == EINTR) continue;
					if (errno == EIO || errno == ENXIO) {
						consecutiveIOErrors++;
						if (consecutiveIOErrors > maxConsecutiveIOErrors) {
							ok = NO;
							err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
												   userInfo:@{NSLocalizedDescriptionKey :
																  [NSString stringWithFormat:@"Read failed repeatedly: %s", strerror(errno)]}];
							break;
						}
						usleep(200000);
						continue;
					}
					ok = NO;
					err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
										   userInfo:@{NSLocalizedDescriptionKey :
														  [NSString stringWithFormat:@"Read error: %s", strerror(errno)]}];
					break;
				} else if (n == 0) break; // EOF

				consecutiveIOErrors = 0;

				size_t written = 0;
				while (written < n) {
					ssize_t w = write(outFd, (char*)buffer + written, n - written);
					if (w < 0) {
						if (errno != EINTR) {
							ok = NO;
							err = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
												   userInfo:@{NSLocalizedDescriptionKey :
																  [NSString stringWithFormat:@"Write error: %s", strerror(errno)]}];
							break;
						}
						continue; // retry on EINTR
					}
					written += w;
				}
				if (!ok) break;

				copied += n;
				if (progressBlock) {
					double fraction = (double)copied / (double)totalSize;
					dispatch_async(dispatch_get_main_queue(), ^{ progressBlock(fraction); });
				}
			}
		}


		if (cuePath) writeCUEFile(cuePath, isoPath.lastPathComponent, inFd, &err);

		free(buffer);
		close(inFd); close(outFd);

		dispatch_async(dispatch_get_main_queue(), ^{
			if (shouldCancel && shouldCancel())
				completionBlock([NSError errorWithDomain:@"DiscDrain" code:-999 userInfo:@{NSLocalizedDescriptionKey : @"Cancelled"}]);
			else
				completionBlock(ok ? nil : err);
		});
	});
}


+ (void)getMD5Sum:(NSString*)filePath
	   completion:(void (^)(NSError* error, NSString* md5sum))completionBlock
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:filePath];
		if (!handle)
		{
			NSError* err = [NSError errorWithDomain:@"DiscDrain"
											   code:10
										   userInfo:@{NSLocalizedDescriptionKey : @"Failed to open file for MD5"}];
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock(err, nil);
			});
			return;
		}

		CC_MD5_CTX ctx;
		CC_MD5_Init(&ctx);

		@try
		{
			while (true)
			{
				@autoreleasepool
				{
					NSData* data = [handle readDataOfLength:1024 * 1024 * 5]; // 5 MB chunks
					if (data.length == 0)
						break;
					CC_MD5_Update(&ctx, data.bytes, (CC_LONG)data.length);
				}
			}
		}
		@catch (NSException* ex)
		{
			[handle closeFile];
			NSError* err = [NSError errorWithDomain:@"DiscDrain"
											   code:11
										   userInfo:@{NSLocalizedDescriptionKey : ex.reason}];
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock(err, nil);
			});
			return;
		}

		[handle closeFile];

		unsigned char digest[CC_MD5_DIGEST_LENGTH];
		CC_MD5_Final(digest, &ctx);

		NSMutableString* md5String = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
		for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
		{
			[md5String appendFormat:@"%02x", digest[i]];
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			completionBlock(nil, md5String);
		});
	});
}

+ (void)getSHA256Sum:(NSString*)filePath
		  completion:(void (^)(NSError* error, NSString* sha256String))completionBlock
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:filePath];
		if (!handle)
		{
			NSError* err = [NSError errorWithDomain:@"DiscDrain"
											   code:10
										   userInfo:@{NSLocalizedDescriptionKey : @"Failed to open file for SHA256"}];
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock(err, nil);
			});
			return;
		}

		CC_SHA256_CTX ctx;
		CC_SHA256_Init(&ctx);

		@try
		{
			while (true)
			{
				@autoreleasepool
				{
					NSData* data = [handle readDataOfLength:1024 * 1024 * 5]; // 5 MB chunks
					if (data.length == 0)
						break;
					CC_SHA256_Update(&ctx, data.bytes, (CC_LONG)data.length);
				}
			}
		}
		@catch (NSException* ex)
		{
			[handle closeFile];
			NSError* err = [NSError errorWithDomain:@"DiscDrain"
											   code:11
										   userInfo:@{NSLocalizedDescriptionKey : ex.reason}];
			dispatch_async(dispatch_get_main_queue(), ^{
				completionBlock(err, nil);
			});
			return;
		}

		[handle closeFile];

		unsigned char digest[CC_SHA256_DIGEST_LENGTH];
		CC_SHA256_Final(digest, &ctx);

		NSMutableString* sha256String = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
		for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
		{
			[sha256String appendFormat:@"%02x", digest[i]];
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			completionBlock(nil, sha256String);
		});
	});
}


+ (BOOL)unmountDiskAtBSDPath:(NSString*)bsdPath
{
	DASessionRef session = DASessionCreate(kCFAllocatorDefault);
	if (!session)
		return false;

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [bsdPath UTF8String]);
	if (!disk)
	{
		CFRelease(session);
		return false;
	}

	DADiskUnmount(disk, kDADiskUnmountOptionDefault, NULL, NULL);

	CFRelease(disk);
	CFRelease(session);
	return true;
}

+ (BOOL)isDiskMountedAtBSDPath:(NSString*)bsdPath
{
	DASessionRef session = DASessionCreate(kCFAllocatorDefault);
	if (!session)
		return NO;

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [bsdPath UTF8String]);
	if (!disk)
	{
		CFRelease(session);
		return NO;
	}

	CFDictionaryRef desc = DADiskCopyDescription(disk);
	BOOL mounted = NO;

	if (desc)
	{
		CFURLRef mountPath = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey);
		mounted = (mountPath != NULL);
		CFRelease(desc);
	}

	CFRelease(disk);
	CFRelease(session);
	return mounted;
}



typedef void (^EjectCompletion)(BOOL success, NSError* error);

static void ejectCallback(DADiskRef disk, DADissenterRef dissenter, void* context)
{
	NSDictionary* info = (__bridge_transfer NSDictionary*)context;
	EjectCompletion completion = info[@"completion"];

	BOOL success = (dissenter == NULL);
	NSError* error = nil;

	if (!success)
	{
		DAReturn err = DADissenterGetStatus(dissenter);

		const char* cstr = mach_error_string(err);
		NSString* desc = cstr ? [NSString stringWithUTF8String:cstr] : @"Unknown Disk Arbitration error";

		error = [NSError errorWithDomain:@"DiscDrain"
									code:err
								userInfo:@{NSLocalizedDescriptionKey : desc}];
	}


	if (completion)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(success, error);
		});
	}

	// Release the session that was retained in the context
	DASessionRef session = (__bridge DASessionRef)info[@"session"];
	CFRelease(session);
}

+ (void)ejectDiskAtBSDPath:(NSString*)bsdPath completion:(void (^)(BOOL success, NSError* error))completion
{
	DASessionRef session = DASessionCreate(kCFAllocatorDefault);
	if (!session)
	{
		if (completion)
			completion(NO, [NSError errorWithDomain:@"DiscDrain"
											   code:20
										   userInfo:@{NSLocalizedDescriptionKey : @"Failed to create Disk Arbitration session"}]);
		return;
	}

	DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, [bsdPath UTF8String]);
	if (!disk)
	{
		if (completion)
			completion(NO, [NSError errorWithDomain:@"DiscDrain"
											   code:21
										   userInfo:@{NSLocalizedDescriptionKey : @"Failed to get disk from BSD path"}]);
		CFRelease(session);
		return;
	}


	// Schedule the session on the main run loop to ensure callback fires
	DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

	// Create a context dictionary to hold the completion and session
	NSDictionary* context = @{
		@"completion" : completion ?: ^(BOOL success, NSError* error){
									  },
		@"session" : (__bridge id)session
	};

	// Retain context for the callback
	CFRetain((__bridge CFTypeRef)(context));

	DADiskEject(disk, kDADiskEjectOptionDefault, ejectCallback, (__bridge void*)context);
}
@end

//
//  DiscInstance.m
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import "DiscInstance.h"
#import <DiskArbitration/DiskArbitration.h>
#import <IOKit/storage/IOMedia.h>

@implementation DiscInstance

- (instancetype)initWithType:(DiscType)type path:(NSString*)bsdPath rpath:(NSString*)rbsdPath
{
	self = [super init];
	if (self)
	{
		_type = type;
		_bsdPath = [bsdPath copy];
		_rbsdPath = [rbsdPath copy];
	}
	return self;
}

+ (nullable instancetype)instanceFromDescription:(CFDictionaryRef)desc
{
	if (!desc)
		return nil;

	// bsd name
	CFStringRef bsdNameRef = CFDictionaryGetValue(desc, kDADiskDescriptionMediaBSDNameKey);
	if (!bsdNameRef)
		return nil;

	NSString* bsdName = (__bridge NSString*)bsdNameRef;
	NSString* bsdPath = [@"/dev/" stringByAppendingString:bsdName];
	NSString* rbsdPath = [@"/dev/r" stringByAppendingString:bsdName];

	// media content
	CFStringRef contentRef = CFDictionaryGetValue(desc, kDADiskDescriptionMediaContentKey);
	DiscType type = DiscTypeDVD; // default

	if (contentRef)
	{
		if (CFStringCompare(contentRef, CFSTR(kIOCDMediaClass), 0) == kCFCompareEqualTo)
		{
			type = DiscTypeCD;
		}
		else if (CFStringCompare(contentRef, CFSTR(kIODVDMediaClass), 0) == kCFCompareEqualTo)
		{
			type = DiscTypeDVD;
		}
		else if (CFStringCompare(contentRef, CFSTR(kIOBDMediaClass), 0) == kCFCompareEqualTo)
		{
			type = DiscTypeBluRay;
		}
	}

	return [[self alloc] initWithType:type path:bsdPath rpath:rbsdPath];
}

@end

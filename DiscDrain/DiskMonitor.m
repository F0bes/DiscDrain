//
//  DiskMonitor.m
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-30.
//

#import "DiskMonitor.h"
#import "DiscInstance.h"
#import <DiskArbitration/DiskArbitration.h>

@interface DiskMonitor ()
@property (nonatomic) DASessionRef session;
@property (nonatomic) dispatch_queue_t queue;
@end

@implementation DiskMonitor

- (instancetype)init {
	self = [super init];
	if (self) {
		_queue = dispatch_queue_create("com.discdrain.diskmonitor", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

static void DiskAppearedCallback(DADiskRef disk, void *context) {
	DiskMonitor *self = (__bridge DiskMonitor *)context;
	CFDictionaryRef desc = DADiskCopyDescription(disk);
	if (!desc) return;

	DiscInstance *instance = [DiscInstance instanceFromDescription:desc];
	CFRelease(desc);

	if (instance && self.delegate) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self.delegate diskDidAppear:instance];
		});
	}
}

static void DiskDisappearedCallback(DADiskRef disk, void *context) {
	DiskMonitor *self = (__bridge DiskMonitor *)context;
	CFDictionaryRef desc = DADiskCopyDescription(disk);
	if (!desc) return;

	DiscInstance *instance = [DiscInstance instanceFromDescription:desc];
	CFRelease(desc);

	if (instance && self.delegate) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self.delegate diskDidDisappear:instance];
		});
	}
}

- (void)startMonitoring {
	if (self.session) return;

	self.session = DASessionCreate(kCFAllocatorDefault);
	if (!self.session) return;

	DASessionSetDispatchQueue(self.session, self.queue);

	DARegisterDiskAppearedCallback(self.session, NULL, DiskAppearedCallback, (__bridge void *)self);
	DARegisterDiskDisappearedCallback(self.session, NULL, DiskDisappearedCallback, (__bridge void *)self);
}

- (void)stopMonitoring {
	if (!self.session) return;

	DAUnregisterCallback(self.session, DiskAppearedCallback, (__bridge void *)self);
	DAUnregisterCallback(self.session, DiskDisappearedCallback, (__bridge void *)self);

	DASessionSetDispatchQueue(self.session, NULL);
	CFRelease(self.session);
	self.session = NULL;
}

@end

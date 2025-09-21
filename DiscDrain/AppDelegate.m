//
//  AppDelegate.m
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import "AppDelegate.h"
#import "DiskMonitor.h"
#import "IOKitManager.h"

@interface AppDelegate () <DiskMonitorDelegate>

@property(strong) IBOutlet NSWindow* window;
@property(nonatomic, strong) NSArray<DiscInstance*>* cdDrives;
@property(nonatomic, strong) NSURL* outputPath;
@property(nonatomic, strong) DiskMonitor* diskMonitor;
@property(nonatomic, assign) BOOL rippingInProgress;
@property(atomic, assign) BOOL shouldCancelRip;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification
{
	[self reloadDrives];

	self.diskMonitor = [[DiskMonitor alloc] init];
	self.diskMonitor.delegate = self;
	[self.diskMonitor startMonitoring];

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    self.window.title = [NSString stringWithFormat:@"DiscDrain (%@)", version];
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app
{
	return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
	return YES;
}

#pragma mark - DiskMonitorDelegate

- (void)diskDidAppear:(DiscInstance*)disc
{
	[self reloadDrives];
	self.statusLabel.stringValue = [NSString stringWithFormat:@"Inserted %@", disc.bsdPath];
}

- (void)diskDidDisappear:(DiscInstance*)disc
{
	[self reloadDrives];
	self.statusLabel.stringValue = [NSString stringWithFormat:@"Ejected %@", disc.bsdPath];
}

- (void)reloadDrives
{
	self.cdDrives = [IOKitManager listDiscs];
	[self.drivePopup removeAllItems];

	for (DiscInstance* disc in self.cdDrives)
	{
		NSString* typeStr = (disc.type == DiscTypeDVD) ? @"DVD" : @"CD";
		NSString* title = [NSString stringWithFormat:@"%@ — %@", typeStr, disc.bsdPath];
		[self.drivePopup addItemWithTitle:title];
	}
}

- (IBAction)radioChanged:(NSButton*)sender
{
	for (NSButton* btn in self.radioButtons)
	{
		if (btn != sender)
		{
			btn.state = NSControlStateValueOff;
		}
	}
}

- (IBAction)refreshDrives:(id)sender
{
	[self reloadDrives];
}

- (IBAction)ejectDisc:(id)sender
{
	NSInteger selectedIndex = self.drivePopup.indexOfSelectedItem;
	if (selectedIndex < 0 || selectedIndex >= self.cdDrives.count)
		return;

	DiscInstance* disc = self.cdDrives[selectedIndex];

	// Unmount if mounted
	if ([IOKitManager isDiskMountedAtBSDPath:disc.bsdPath])
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @"Disc is Mounted";
		alert.informativeText = [NSString stringWithFormat:
				@"The disc at %@ is currently mounted. Do you want to unmount it before ejecting?",
			disc.bsdPath];
		[alert addButtonWithTitle:@"Unmount"];
		[alert addButtonWithTitle:@"Cancel"];
		alert.alertStyle = NSAlertStyleWarning;

		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;

		if (![IOKitManager unmountDiskAtBSDPath:disc.bsdPath])
		{
			NSAlert* err = [[NSAlert alloc] init];
			err.messageText = @"Failed to Unmount";
			err.informativeText = @"Could not unmount the disc.";
			[err runModal];
			return;
		}
	}

	[IOKitManager ejectDiskAtBSDPath:disc.bsdPath
						  completion:^(BOOL success, NSError* error) {
							  dispatch_async(dispatch_get_main_queue(), ^{
								  self.statusLabel.stringValue = success ? @"Ejected" : [NSString stringWithFormat:@"Error ejecting: %@", error.localizedDescription];
							  });
						  }];
}

- (IBAction)loadNameFromDisc:(id)sender
{
	NSInteger selectedIndex = self.drivePopup.indexOfSelectedItem;
	if (selectedIndex < 0 || selectedIndex >= self.cdDrives.count)
		return;

	DiscInstance* disc = self.cdDrives[selectedIndex];
	NSString* discName = [IOKitManager discNameForDiscInstance:disc] ?: @"unknown";
	NSString* discExtension;
	switch (disc.type)
	{
		case DiscTypeCD:
			discExtension = @".bin";
			break;
		case DiscTypeDVD:
			discExtension = @".iso";
			break;
		default:
			discExtension = @".iso";
			break;
	}

	self.outputTextField.stringValue = [discName stringByAppendingString:discExtension];
}

- (IBAction)browseOutput:(id)sender
{
	NSOpenPanel* openPanel = [NSOpenPanel openPanel];
	openPanel.canChooseFiles = NO;
	openPanel.canChooseDirectories = YES;
	openPanel.allowsMultipleSelection = NO;

	if ([openPanel runModal] == NSModalResponseOK)
	{
		self.outputPath = openPanel.URL;
		self.outputPathTextField.stringValue = self.outputPath.path;
	}
}

- (IBAction)openOutput:(id)sender
{
	if (self.outputPathTextField.stringValue == nil || [self.outputPathTextField.stringValue length] == 0)
		return;

	NSString* openFilePath = self.outputPathTextField.stringValue;

	if (self.outputTextField.stringValue != nil && [self.outputPathTextField.stringValue length] != 0)
	{
		openFilePath = [openFilePath stringByAppendingFormat:@"/%@", self.outputTextField.stringValue];
		if ([[NSFileManager defaultManager] fileExistsAtPath:openFilePath])
		{
			[[NSWorkspace sharedWorkspace] selectFile:openFilePath inFileViewerRootedAtPath:@""];
			return;
		}
		else
		{
			openFilePath = [openFilePath stringByDeletingLastPathComponent];
		}
	}

	// Just open the directory
	[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:openFilePath]];
}

- (IBAction)ripDisc:(id)sender
{
	if (self.rippingInProgress)
	{
		self.shouldCancelRip = YES;
		self.statusLabel.stringValue = @"Cancelling...";
		return;
	}

	NSInteger selectedIndex = self.drivePopup.indexOfSelectedItem;
	if (selectedIndex < 0 || selectedIndex >= self.cdDrives.count)
	{
		NSLog(@"No disc selected");
		return;
	}

	DiscInstance* disc = self.cdDrives[selectedIndex];

	if(disc.type == DiscTypeCD)
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @"This ain't a DVD!";
		alert.informativeText = @"DiscDrain probably doesn't work with CDs, expect a bad bin if you proceed";
		[alert addButtonWithTitle:@"Proceed"];
		[alert addButtonWithTitle:@"Cancel"];
		alert.alertStyle = NSAlertStyleWarning;
		
		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;
	}
	
	// Unmount if mounted
	if ([IOKitManager isDiskMountedAtBSDPath:disc.bsdPath])
	{
		NSAlert* alert = [[NSAlert alloc] init];
		alert.messageText = @"Disc is Mounted";
		alert.informativeText = [NSString stringWithFormat:
				@"The disc at %@ is currently mounted. Do you want to unmount it before ripping?",
			disc.bsdPath];
		[alert addButtonWithTitle:@"Unmount"];
		[alert addButtonWithTitle:@"Cancel"];
		alert.alertStyle = NSAlertStyleWarning;

		if ([alert runModal] != NSAlertFirstButtonReturn)
			return;

		if (![IOKitManager unmountDiskAtBSDPath:disc.bsdPath])
		{
			NSAlert* err = [[NSAlert alloc] init];
			err.messageText = @"Failed to Unmount";
			err.informativeText = @"Could not unmount the disc.";
			[err runModal];
			return;
		}
	}

	NSURL* binURL = [self.outputPath URLByAppendingPathComponent:self.outputTextField.stringValue];
	NSString* binPath = binURL.path;
	NSString* cuePath = nil;
	if(disc.type == DiscTypeCD)
	{
		cuePath = [[binPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"cue"];
	}

	[self.progressBar setDoubleValue:0.0];
	[self.progressBar setHidden:NO];
	[self.statusLabel setStringValue:@"Ripping"];
	[self.refreshButton setEnabled:NO];
	[self.ejectButton setEnabled:NO];
	[self.loadNameFromDiscButton setEnabled:NO];
	[self.browseOutputButton setEnabled:NO];
	[self.openOutputButton setEnabled:NO];
	[self.md5Checkbox setEnabled:NO];
	[self.sha256Checkbox setEnabled:NO];
	[self.outputTextField setEnabled:NO];
	[self.outputPathTextField setEnabled:NO];
	[self.drivePopup setEnabled:NO];
	[self.ripButton setTitle:@"Cancel"];
	self.rippingInProgress = YES;
	self.shouldCancelRip = NO;

	[IOKitManager ripDisc:disc
		toPath:binPath
	   cuePath: cuePath
		progress:^(double fraction) {
			dispatch_async(dispatch_get_main_queue(), ^{
				self.progressBar.doubleValue = fraction * 100.0;
			});
		}
		shouldCancel:^BOOL {
			return self.shouldCancelRip;
		}
		completion:^(NSError* error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (error)
				{
					self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
				}
				else
				{
					self.statusLabel.stringValue = @"Rip complete!";
					[self.statusLabel setStringValue:@"Rip complete!"];
					[self handleChecksumsIfNeeded:binPath];
				}
				[self.refreshButton setEnabled:YES];
				[self.ejectButton setEnabled:YES];
				[self.loadNameFromDiscButton setEnabled:YES];
				[self.browseOutputButton setEnabled:YES];
				[self.openOutputButton setEnabled:YES];
				[self.md5Checkbox setEnabled:YES];
				[self.sha256Checkbox setEnabled:YES];
				[self.outputTextField setEnabled:YES];
				[self.outputPathTextField setEnabled:YES];
				[self.drivePopup setEnabled:YES];
				[self.ripButton setTitle:@"Rip"];
				self.rippingInProgress = NO;
			});
		}];
}

- (void)handleChecksumsIfNeeded:(NSString*)isoPath
{
	if (self.md5Checkbox.state == NSControlStateValueOn)
	{
		self.statusLabel.stringValue = @"Calculating MD5...";
		[IOKitManager getMD5Sum:isoPath
					 completion:^(NSError* error, NSString* md5sum) {
						 dispatch_async(dispatch_get_main_queue(), ^{
							 self.md5Label.stringValue = error ? error.localizedDescription : md5sum;
							 if (!error && self.sha256Checkbox.state == NSControlStateValueOn)
							 {
								 [self calculateSHA256:isoPath];
							 }
							 else
							 {
								 self.statusLabel.stringValue = @"Completed";
							 }
						 });
					 }];
	}
	else if (self.sha256Checkbox.state == NSControlStateValueOn)
	{
		[self calculateSHA256:isoPath];
	}
}

- (void)calculateSHA256:(NSString*)isoPath
{
	self.statusLabel.stringValue = @"Calculating SHA256...";
	[IOKitManager getSHA256Sum:isoPath
					completion:^(NSError* error, NSString* sha256sum) {
						dispatch_async(dispatch_get_main_queue(), ^{
							self.sha256Label.stringValue = error ? error.localizedDescription : sha256sum;
							self.statusLabel.stringValue = @"Completed";
						});
					}];
}

@end

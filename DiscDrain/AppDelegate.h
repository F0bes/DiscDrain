//
//  AppDelegate.h
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, weak) IBOutlet NSPopUpButton *drivePopup;
@property (nonatomic, weak) IBOutletCollection(NSButton) NSArray<NSButton *> *radioButtons;
- (IBAction)radioChanged:(NSButton *)sender;

@property (nonatomic, weak) IBOutlet NSButton *refreshButton;
- (IBAction)refreshDrives:(id)sender;

@property (nonatomic, weak) IBOutlet NSButton *ejectButton;
- (IBAction)ejectDisc:(id)sender;

@property (nonatomic, weak) IBOutlet NSTextField *outputTextField;
@property (nonatomic, weak) IBOutlet NSButton *loadNameFromDiscButton;
- (IBAction)loadNameFromDisc:(id)sender;

@property (nonatomic, weak) IBOutlet NSTextField *outputPathTextField;
@property (nonatomic, weak) IBOutlet NSButton *browseOutputButton;
- (IBAction)browseOutput:(id)sender;

@property (nonatomic, weak) IBOutlet NSButton *openOutputButton;
- (IBAction)openOutput:(id)sender;

@property (nonatomic, weak) IBOutlet NSButton *ripButton;
- (IBAction)ripDisc:(id)sender;

@property (nonatomic, weak) IBOutlet NSProgressIndicator *progressBar;
@property (nonatomic, weak) IBOutlet NSTextField *statusLabel;

@property (nonatomic, weak) IBOutlet NSButton *md5Checkbox;
@property (nonatomic, weak) IBOutlet NSTextField *md5Label;

@property (nonatomic, weak) IBOutlet NSButton *sha256Checkbox;
@property (nonatomic, weak) IBOutlet NSTextField *sha256Label;

@end

//
//  DiskMonitor.h
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-30.
//

#import <Foundation/Foundation.h>
@class DiscInstance;

NS_ASSUME_NONNULL_BEGIN

@protocol DiskMonitorDelegate <NSObject>
- (void)diskDidAppear:(DiscInstance *)disc;
- (void)diskDidDisappear:(DiscInstance *)disc;
@end

@interface DiskMonitor : NSObject
@property (nonatomic, weak) id<DiskMonitorDelegate> delegate;

- (instancetype)init;
- (void)startMonitoring;
- (void)stopMonitoring;
@end

NS_ASSUME_NONNULL_END

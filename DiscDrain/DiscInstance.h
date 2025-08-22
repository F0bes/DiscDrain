//
//  DiscInstance.h
//  DiscDrain
//
//  Created by Ty Lamontagne on 2025-08-22.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DiscType) {
	DiscTypeCD,
	DiscTypeDVD,
	DiscTypeBluRay
};

NS_ASSUME_NONNULL_BEGIN

@interface DiscInstance : NSObject

@property (nonatomic, readonly) DiscType type;
@property (nonatomic, copy, readonly) NSString *bsdPath;
@property (nonatomic, copy, readonly) NSString *rbsdPath;

- (instancetype)initWithType:(DiscType)type
						path:(NSString *)bsdPath
					   rpath:(NSString *)rbsdPath;

/// Create a DiscInstance from a DiskArbitration description dictionary
+ (nullable instancetype)instanceFromDescription:(CFDictionaryRef)desc;

@end

NS_ASSUME_NONNULL_END

//  Created by Adam Kaplan on 8/1/15.
//  Copyright 2015 Yahoo.
//  Licensed under the terms of the MIT License. See LICENSE file in the project root.

#import "YMMemoryCache.h"
#import <os/lock.h>

//#if defined(__MAC_10_12) || defined(__IPHONE_10_0) || defined(__WATCHOS_3_0) || defined(__TVOS_10_0)
//    #import <sys/kdebug_signpost.h>
//#else
//    #define kdebug_signpost(...) do {} while(0);
//    #define kdebug_signpost_start(...) do {} while(0);
//    #define kdebug_signpost_end(...) do {} while(0);
//#endif

#define AssertPrivateQueue \
NSAssert(dispatch_get_specific(kYFPrivateQueueKey) == (__bridge void *)self, @"Wrong Queue")

#define AssertNotPrivateQueue \
NSAssert(dispatch_get_specific(kYFPrivateQueueKey) != (__bridge void *)self, @"Potential deadlock: blocking call issued from current queue, to current queue")

#define IsPrivateQueue (dispatch_get_specific(kYFPrivateQueueKey) == (__bridge void *)self)

NSString *const kYFCacheDidChangeNotification = @"kYFCacheDidChangeNotification";
NSString *const kYFCacheUpdatedItemsUserInfoKey = @"kYFCacheUpdatedItemsUserInfoKey";
NSString *const kYFCacheRemovedItemsUserInfoKey = @"kYFCacheRemovedItemsUserInfoKey";


static const CFStringRef kYFPrivateQueueKey = CFSTR("kYFPrivateQueueKey");

@interface YMMemoryCache ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t notificationTimer;
@property (nonatomic) dispatch_source_t evictionTimer;
/// All of the key-value pairs stored in the cache
@property (nonatomic) NSMutableDictionary *items;
/// The keys (and their current value) that have been added/updated since the last kYFCacheDidChangeNotification
@property (nonatomic) NSMutableDictionary *updatedPendingNotify;
/// The keys that have been removed since the last kYFCacheDidChangeNotification
@property (nonatomic) NSMutableSet *removedPendingNotify;

@property (nonatomic, copy) YMMemoryCacheEvictionDecider evictionDecider;
@property (nonatomic) dispatch_queue_t evictionDeciderQueue;

@end

@implementation YMMemoryCache {
    os_unfair_lock _unfairLock;
}

#pragma mark - Lifecycle

+ (instancetype)memoryCacheWithName:(NSString *)name {
    return [[self alloc] initWithName:name evictionDecider:nil];
}

+ (instancetype)memoryCacheWithName:(NSString *)name evictionDecider:(YMMemoryCacheEvictionDecider)evictionDecider {
    return [[self alloc] initWithName:name evictionDecider:evictionDecider];
}

- (instancetype)initWithName:(NSString *)cacheName evictionDecider:(YMMemoryCacheEvictionDecider)evictionDecider {
    return [self initWithName:cacheName targetQueue:nil evictionDecider:evictionDecider];
}

- (instancetype)initWithName:(NSString *)cacheName targetQueue:(nullable dispatch_queue_t)targetQueue
             evictionDecider:(YMMemoryCacheEvictionDecider)evictionDecider {
    
    if (self = [super init]) {
        
        NSString *queueName = @"com.yahoo.cache";
        if (cacheName) {
            _name = cacheName;
            queueName = [queueName stringByAppendingFormat:@" %@", cacheName];
        }
        
        _queue = dispatch_queue_create_with_target(queueName.UTF8String, DISPATCH_QUEUE_CONCURRENT, targetQueue);
        dispatch_queue_set_specific(_queue, kYFPrivateQueueKey, (__bridge void *)self, NULL);
        
        _unfairLock = OS_UNFAIR_LOCK_INIT;
        
        if (evictionDecider) {
            _evictionDecider = evictionDecider;
            NSString *evictionQueueName = [queueName stringByAppendingString:@" (eviction)"];
            _evictionDeciderQueue = dispatch_queue_create_with_target(evictionQueueName.UTF8String, DISPATCH_QUEUE_SERIAL, targetQueue);
            
            // Time interval to notify UI. This sets the overall update cadence for the app.
            [self setEvictionInterval:600.0];
        }
        
        [self setNotificationInterval:0.0];
        
        _items = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    self.queue = nil; // kill queue, then kill timers
    self.evictionDeciderQueue = nil;
    
    dispatch_source_t evictionTimer = self.evictionTimer;
    if (evictionTimer && 0 == dispatch_source_testcancel(evictionTimer)) {
        dispatch_source_cancel(evictionTimer);
    }
    
    dispatch_source_t notificationTimer = self.notificationTimer;
    if (notificationTimer && 0 == dispatch_source_testcancel(notificationTimer)) {
        dispatch_source_cancel(notificationTimer);
    }
}

#pragma mark - Persistence

- (void)addEntriesFromDictionary:(NSDictionary *)dictionary {
    os_unfair_lock_lock(&_unfairLock);
    [self.items addEntriesFromDictionary:dictionary];
    os_unfair_lock_unlock(&_unfairLock);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        [weakSelf.updatedPendingNotify addEntriesFromDictionary:dictionary];
        for (id key in dictionary) {
            [weakSelf.removedPendingNotify removeObject:key];
        }
    });
}

- (NSDictionary *)allItems {
    os_unfair_lock_lock(&_unfairLock);
    NSDictionary *items = [self.items copy];
    os_unfair_lock_unlock(&_unfairLock);
    
    return items;
}

#pragma mark - Property Setters

- (void)setEvictionInterval:(NSTimeInterval)evictionInterval {
    if (!self.evictionDeciderQueue) { // abort if this instance was not configured with an evictionDecider
        return;
    }
    
    dispatch_barrier_async(self.evictionDeciderQueue, ^{
        self->_evictionInterval = evictionInterval;
        
        if (self.evictionTimer) {
            dispatch_source_cancel(self.evictionTimer);
            self.evictionTimer = nil;
        }
        
        if (evictionInterval > 0) {
            self.evictionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.evictionDeciderQueue);
            
            __weak __typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(self.evictionTimer, ^{ [weakSelf purgeEvictableItems:NULL]; });
            
            dispatch_source_set_timer(self.evictionTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (SInt64)(evictionInterval * NSEC_PER_SEC)),
                                      (UInt64)(self.evictionInterval * NSEC_PER_SEC),
                                      5 * NSEC_PER_MSEC);
            
            dispatch_resume(self.evictionTimer);
        }
    });
}

- (void)setNotificationInterval:(NSTimeInterval)notificationInterval {
    
    dispatch_barrier_async(self.queue, ^{
        self->_notificationInterval = notificationInterval;
        
        if (self.notificationTimer) {
            dispatch_source_cancel(self.notificationTimer);
            self.notificationTimer = nil;
        }
        
        if (self.notificationInterval > 0) {
            self.updatedPendingNotify = [NSMutableDictionary dictionary];
            self.removedPendingNotify = [NSMutableSet set];
            
            self.notificationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
            
            __weak __typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(self.notificationTimer, ^{
                [weakSelf sendPendingNotifications];
            });
            
            dispatch_source_set_timer(self.notificationTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (SInt64)(self.notificationInterval * NSEC_PER_SEC)),
                                      (UInt64)(self.notificationInterval * NSEC_PER_SEC),
                                      5 * NSEC_PER_MSEC);
            
            dispatch_resume(self.notificationTimer);
        }
        else {
            self.updatedPendingNotify = nil;
            self.removedPendingNotify = nil;
        }
    });
}

#pragma mark - Keyed Subscripting

- (id)objectForKeyedSubscript:(id)key {
    os_unfair_lock_lock(&_unfairLock);
    id item = self.items[key];
    os_unfair_lock_unlock(&_unfairLock);
    return item;
}

- (void)setObject:(id)obj forKeyedSubscript:(id)key {
    NSParameterAssert(key); // The collections will assert, but fail earlier to aid in async debugging
    if (!key) {
        return;
    }
    
    os_unfair_lock_lock(&_unfairLock);
    if (obj) {
        self.items[key] = obj;
    } else { // removing existing key if nil was passed in
        [self.items removeObjectForKey:key];
    }
    os_unfair_lock_unlock(&_unfairLock);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        if (obj) {
            [weakSelf.removedPendingNotify removeObject:key];
            weakSelf.updatedPendingNotify[key] = obj;
        } else {
            [weakSelf.removedPendingNotify addObject:key];
            [weakSelf.updatedPendingNotify removeObjectForKey:key];
        }
    });
}

#pragma mark - Key-Value Management

- (void)removeAllObjects {
    os_unfair_lock_lock(&_unfairLock);
    NSDictionary *items = self.items;
    self.items = [NSMutableDictionary new];
    os_unfair_lock_unlock(&_unfairLock);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        for (id key in items) {
            [weakSelf.updatedPendingNotify removeObjectForKey:key];
            [weakSelf.removedPendingNotify addObject:key];
        }
    });
}

- (void)removeObjectsForKeys:(NSArray *)keys {
    if (!keys.count) {
        return;
    }
    
    os_unfair_lock_lock(&_unfairLock);
    [self.items removeObjectsForKeys:keys];
    os_unfair_lock_unlock(&_unfairLock);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        [weakSelf.removedPendingNotify addObjectsFromArray:keys];
        [weakSelf.updatedPendingNotify removeObjectsForKeys:keys];
    });
}

#pragma mark - Notification

- (void)sendPendingNotifications {
    AssertPrivateQueue;
    
    NSDictionary *updatedPending = self.updatedPendingNotify ? self.updatedPendingNotify : @{};
    NSSet *removedPending = self.removedPendingNotify ? self.removedPendingNotify : [NSSet set];
    if (!updatedPending.count && !removedPending.count) {
        return;
    }
    self.updatedPendingNotify = [NSMutableDictionary dictionary];
    self.removedPendingNotify = [NSMutableSet set];
    
    dispatch_async(dispatch_get_main_queue(), ^{ // does not require a barrier since setObject: is the only other mutator
        [[NSNotificationCenter defaultCenter] postNotificationName:kYFCacheDidChangeNotification
                                                            object:self
                                                          userInfo:@{ kYFCacheUpdatedItemsUserInfoKey: updatedPending,
                                                                      kYFCacheRemovedItemsUserInfoKey: removedPending }];
    });
}

#pragma mark - Cleanup

- (void)purgeEvictableItems:(void *)context {
    // All external execution must have been dispatched to another queue so as to not leak the private queue
    // though the user-provided evictionDecider block.
    //AssertNotPrivateQueue;
    
    // Don't clean up if no expiration decider block
    if (!self.evictionDecider) {
        return;
    }
    
    NSDictionary *items = self.allItems; // sync & safe
    YMMemoryCacheEvictionDecider evictionDecider = self.evictionDecider;
    NSMutableArray *itemKeysToPurge = [NSMutableArray new];
    
    for (id key in items) {
        id value = items[key];
        
        BOOL shouldEvict = evictionDecider(key, value, context);
        if (shouldEvict) {
            [itemKeysToPurge addObject:key];
        }
    }
    
    [self removeObjectsForKeys:itemKeysToPurge];
}

@end

//
//  NSObject+KVOCrash.m
//  
//
//  Created by liberty air on 2018/12/14.
//  Copyright © 2018年 . All rights reserved.
//

#import "NSObject+KVOCrash.h"
#import "NSObject+LASwizzle.h"
#import <pthread.h>

#pragma mark - KVOProxy


/**
 此类用来管理混乱的KVO关系
 让被观察对象持有一个KVO的delegate，所有和KVO相关的操作均通过delegate来进行管理，delegate通过建立一张map来维护KVO整个关系
 
 好处：
 不会crash 1.如果出现KVO重复添加观察者或重复移除观察者（KVO注册观察者与移除观察者不匹配）的情况，delegate可以直接阻止这些非正常的操作。
 
 crash 2.被观察对象dealloc之前，可以通过delegate自动将与自己有关的KVO关系都注销掉，避免了KVO的被观察者dealloc时仍然注册着KVO导致的crash。
 
 👇：
 重复添加观察者不会crash，即不会走@catch
 多次添加对同一个属性观察的观察者，系统方法内部会强应用这个观察者，同理即可remove该观察者同样次数。
 
 */
@implementation KVOProxy{
    pthread_mutex_t _mutex;
    NSMapTable<id, NSMutableSet<LAKVOInfo *> *> *_objectInfosMap; ///< map来维护KVO整个关系
}

- (instancetype)init
{
    self = [super init];
    if (nil != self) {
        
        _objectInfosMap = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPersonality capacity:0];
        
        pthread_mutex_init(&_mutex, NULL);
    }
    return self;
}

- (BOOL)la_addObserver:(id)object KVOinfo:(LAKVOInfo *)KVOinfo
{
    [self lock];
    
    // LAKVOInfo 存入KVO的信息，object为注册者对象
    NSMutableSet *infos = [_objectInfosMap objectForKey:object];
    __block BOOL isHas = NO;
    [infos enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
        if([[KVOinfo valueForKey:@"_keyPath"] isEqualToString:[obj valueForKey:@"_keyPath"]]){
            *stop = YES;
            isHas = YES;
        }
    }];
    if(isHas) {
        [self unlock];
        
        NSLog(@"crash add observer: %@, keyPath: %@", object, KVOinfo);

        return NO ;
    }
    if(nil == infos){
        infos = [NSMutableSet set];
        [_objectInfosMap setObject:infos forKey:object];
    }
    [infos addObject:KVOinfo];
    [self unlock];
    
    return YES;
}

- (void)la_removeObserver:(id)object keyPath:(NSString *)keyPath block:(void (^)(void))block
{
//    if (!object || !keyPath) {
//        return;
//    }
    
    [self lock];
    NSMutableSet *infos = [_objectInfosMap objectForKey:object];
    __block LAKVOInfo *info;
    [infos enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
        if([keyPath isEqualToString:[obj valueForKey:@"_keyPath"]]){
            info = (LAKVOInfo *)obj;
            *stop = YES;
        }
    }];
    
    if (info != nil) {
        [infos removeObject:info];
        block();
        if (0 == infos.count) {
            [_objectInfosMap removeObjectForKey:object];
        }
    }else {
        [LACrashLog printCrashMsg:[NSString stringWithFormat:@"Cannot remove an observer %@ for the key path '%@' from %@ because it is not registered as an observer.",object,keyPath,self]];
    }
    [self unlock];
}

- (void)la_removeAllObserver
{
    if (_objectInfosMap) {
        NSMapTable *objectInfoMaps = [_objectInfosMap copy];
        for (id object in objectInfoMaps) {
            
            NSSet *infos = [objectInfoMaps objectForKey:object];
            if(nil==infos || infos.count==0) continue;
            [infos enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
                LAKVOInfo *info = (LAKVOInfo *)obj;
                [object removeObserver:self forKeyPath:[info valueForKey:@"_keyPath"]];
            }];
        }
        [_objectInfosMap removeAllObjects];
    }
}

- (void)observeValueForKeyPath:(nullable NSString *)keyPath ofObject:(nullable id)object change:(nullable NSDictionary<NSKeyValueChangeKey, id> *)change context:(nullable void *)context{
    NSLog(@"KVOProxy - observeValueForKeyPath :%@",change);
    __block LAKVOInfo *info ;
    {
        [self lock];
        NSSet *infos = [_objectInfosMap objectForKey:object];
        [infos enumerateObjectsUsingBlock:^(id  _Nonnull obj, BOOL * _Nonnull stop) {
            if([keyPath isEqualToString:[obj valueForKey:@"_keyPath"]]){
                info = (LAKVOInfo *)obj;
                *stop = YES;
            }
        }];
        [self unlock];
    }
    
    if (nil != info) {
        [object observeValueForKeyPath:keyPath ofObject:object change:change context:(__bridge void * _Nullable)([info valueForKey:@"_context"])];
    }
}

-(void)lock
{
    pthread_mutex_lock(&_mutex);
}

-(void)unlock
{
    pthread_mutex_unlock(&_mutex);
}

- (void)dealloc
{
    [self la_removeAllObserver];
    pthread_mutex_destroy(&_mutex);
//    NSLog(@"KVOProxy dealloc removeAllObserve");
}

@end

#pragma mark - LAKVOInfo
@implementation LAKVOInfo {
    @public
    NSString *_keyPath;
    NSKeyValueObservingOptions _options;
    SEL _action;
    void *_context;
    LAKVONotificationBlock _block;
}

- (instancetype)initWithKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context {
    return [self initWithKeyPath:keyPath options:options block:NULL action:NULL context:context];
}

- (instancetype)initWithKeyPath:(NSString *)keyPath
                        options:(NSKeyValueObservingOptions)options
                          block:(nullable LAKVONotificationBlock)block
                         action:(nullable SEL)action
                        context:(nullable void *)context {
    self = [super init];
    if (nil != self) {
        _block = [block copy];
        _keyPath = [keyPath copy];
        _options = options;
        _action = action;
        _context = context;
    }
    return self;
}

@end

#pragma mark - NSObject + KVOCrash
/**
 
 ①、警告⚠️：
 1、重复添加相同的keyPath观察者，会重复调用 observeValueForKeyPath：...方法
 
 ②、crash情况：
 1、移除未被以KVO注册的观察者 会crash
 2、重复移除观察者 会crash
 
 */

// fix "unrecognized selector" ,"KVC"
static void *NSObjectKVOProxyKey = &NSObjectKVOProxyKey;

@implementation NSObject (KVOCrash)

+ (void)la_enableKVOProtector {

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        NSObject *objc = [[NSObject alloc] init];
        [objc la_instanceSwizzleMethod:@selector(addObserver:forKeyPath:options:context:) replaceMethod:@selector(la_addObserver:forKeyPath:options:context:)];
        [objc la_instanceSwizzleMethod:@selector(removeObserver:forKeyPath:) replaceMethod:@selector(la_removeObserver:forKeyPath:)];
    });
}

/// 添加观察者，实际添加LAKVOInfo -> KVO的管理者，来管理KVO的注册
/**
 keyPath为对象的属性，通过keyPath作为Key创建对应对应的一条观察者关键路径：keyPath --> observer(self)
 
 */
- (void)la_addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context {
    
    LAKVOInfo * kvoInfo = [[LAKVOInfo alloc] initWithKeyPath:keyPath options:options context:context];
    __weak typeof(self) wkself = self;

    if ([self.KVOProxy la_addObserver:wkself KVOinfo:kvoInfo]) {
        [self la_addObserver:observer forKeyPath:keyPath options:options context:context];
    }else {
        NSLog(@"KVO is more");
    }
}

- (void)la_removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath {
    NSLog(@"swizzled removeObserver");
    [self.KVOProxy la_removeObserver:observer keyPath:keyPath block:^{
        [self la_removeObserver:observer forKeyPath:keyPath];
    }];
}

- (KVOProxy *)KVOProxy
{
    id proxy = objc_getAssociatedObject(self, NSObjectKVOProxyKey);
    
    if (nil == proxy) {
        proxy = [[KVOProxy alloc] init];
        self.KVOProxy = proxy;
    }
    
    return proxy;
}

- (void)setKVOProxy:(KVOProxy *)proxy
{
    objc_setAssociatedObject(self, NSObjectKVOProxyKey, proxy, OBJC_ASSOCIATION_ASSIGN);
}

@end

//
//  MQTTKit.m
//  MQTTKit
//
//  Created by Jeff Mesnil on 22/10/2013.
//  Copyright (c) 2013 Jeff Mesnil. All rights reserved.
//  Copyright 2012 Nicholas Humfrey. All rights reserved.
//

#import "MQTTKit.h"
#import "mosquitto.h"

#if 0 // set to 1 to enable logs

#define LogDebug(frmt, ...) NSLog(frmt, ##__VA_ARGS__);

#else

#define LogDebug(frmt, ...) {}

#endif

@interface MQTTMessage()

@property (readwrite, assign) unsigned short mid;
@property (readwrite, copy) NSString *topic;
@property (readwrite, copy) NSData *payload;
@property (readwrite, assign) unsigned short qos;
@property (readwrite, assign) BOOL retained;

@end

@implementation MQTTMessage

-(id)initWithTopic:(NSString *)topic
           payload:(NSData *)payload
               qos:(short)qos
            retain:(BOOL)retained
               mid:(short)mid
{
    if ((self = [super init])) {
        self.topic = topic;
        self.payload = payload;
        self.qos = qos;
        self.retained = retained;
        self.mid = mid;
    }
    return self;
}

- (NSString *)payloadString {
    return [[NSString alloc] initWithBytes:self.payload.bytes length:self.payload.length encoding:NSUTF8StringEncoding];
}

@end

@interface MQTTClient()

@property (nonatomic, assign) BOOL connected;

@end

@implementation MQTTClient

@synthesize clientID;
@synthesize host;
@synthesize port;
@synthesize username;
@synthesize password;
@synthesize keepAlive;
@synthesize cleanSession;
@synthesize delegate;
@synthesize connected;

// dispatch queue to run the mosquitto_loop_forever.
dispatch_queue_t queue;

static void on_connect(struct mosquitto *mosq, void *obj, int rc)
{
    MQTTClient* client = (__bridge MQTTClient*)obj;
    LogDebug(@"on_connect rc = %d", rc);
    client.connected = YES;
    [client.delegate client:client didConnect:rc];
}

static void on_disconnect(struct mosquitto *mosq, void *obj, int rc)
{
    MQTTClient* client = (__bridge MQTTClient*)obj;
    LogDebug(@"on_disconnect rc = %d", rc);
    client.connected = NO;
    if ([client.delegate respondsToSelector:@selector(client:didDisconnect:)]) {
        [client.delegate client:client didDisconnect:rc];
    }
}

static void on_publish(struct mosquitto *mosq, void *obj, int message_id)
{
    MQTTClient* client = (__bridge MQTTClient*)obj;
    if ([client.delegate respondsToSelector:@selector(client:didPublish:)]) {
        [client.delegate client:client didPublish:message_id];
    }
}

static void on_message(struct mosquitto *mosq, void *obj, const struct mosquitto_message *mosq_msg)
{
    NSString *topic = [NSString stringWithUTF8String: mosq_msg->topic];
    NSData *payload = [NSData dataWithBytes:mosq_msg->payload length:mosq_msg->payloadlen];
    MQTTMessage *message = [[MQTTMessage alloc] initWithTopic:topic
                                                      payload:payload
                                                          qos:mosq_msg->qos
                                                       retain:mosq_msg->retain
                                                          mid:mosq_msg->mid];
    MQTTClient* client = (__bridge MQTTClient*)obj;
    if ([client.delegate respondsToSelector:@selector(client:didReceiveMessage:)]) {
        [client.delegate client:client didReceiveMessage:message];
    }
}

static void on_subscribe(struct mosquitto *mosq, void *obj, int message_id, int qos_count, const int *granted_qos)
{
    MQTTClient* client = (__bridge MQTTClient*)obj;
    if ([client.delegate respondsToSelector:@selector(client:didSubscribe:grantedQos:)]) {
        [client.delegate client:client didSubscribe:message_id grantedQos:nil];
    }
}

static void on_unsubscribe(struct mosquitto *mosq, void *obj, int message_id)
{
    MQTTClient* client = (__bridge MQTTClient*)obj;
    if ([client.delegate respondsToSelector:@selector(client:didUnsubscribe:)]) {
        [client.delegate client:client didUnsubscribe:message_id];
    }
}


// Initialize is called just before the first object is allocated
+ (void)initialize {
    mosquitto_lib_init();
}

+ (NSString*)version {
    int major, minor, revision;
    mosquitto_lib_version(&major, &minor, &revision);
    return [NSString stringWithFormat:@"%d.%d.%d", major, minor, revision];
}

- (MQTTClient*) initWithClientId: (NSString*) clientId {
    if ((self = [super init])) {
        self.clientID = clientId;
        [self setHost: nil];
        [self setPort: 1883];
        [self setKeepAlive: 60];
        [self setCleanSession: YES]; //NOTE: this isdisable clean to keep the broker remember this client

        const char* cstrClientId = [self.clientID cStringUsingEncoding:NSUTF8StringEncoding];

        mosq = mosquitto_new(cstrClientId, cleanSession, (__bridge void *)(self));
        mosquitto_connect_callback_set(mosq, on_connect);
        mosquitto_disconnect_callback_set(mosq, on_disconnect);
        mosquitto_publish_callback_set(mosq, on_publish);
        mosquitto_message_callback_set(mosq, on_message);
        mosquitto_subscribe_callback_set(mosq, on_subscribe);
        mosquitto_unsubscribe_callback_set(mosq, on_unsubscribe);

        queue = dispatch_queue_create(cstrClientId, NULL);
    }
    return self;
}


- (void) connect {
    const char *cstrHost = [host cStringUsingEncoding:NSASCIIStringEncoding];
    const char *cstrUsername = NULL, *cstrPassword = NULL;

    if (username)
        cstrUsername = [username cStringUsingEncoding:NSUTF8StringEncoding];

    if (password)
        cstrPassword = [password cStringUsingEncoding:NSUTF8StringEncoding];

    // FIXME: check for errors
    mosquitto_username_pw_set(mosq, cstrUsername, cstrPassword);

    mosquitto_connect(mosq, cstrHost, port, keepAlive);
    
    dispatch_async(queue, ^{
        LogDebug(@"start mosquitto loop");
        mosquitto_loop_forever(mosq, 10, 1);
        LogDebug(@"end mosquitto loop");
    });

    connected = YES;
}

- (void) connectToHost: (NSString*)aHost {
    [self setHost:aHost];
    [self connect];
}

- (void) reconnect {
    mosquitto_reconnect(mosq);
}

- (void) disconnect {
    mosquitto_disconnect(mosq);
}

- (void)setWillData:(NSData *)payload toTopic:(NSString *)willTopic withQos:(NSUInteger)willQos retain:(BOOL)retain
{
    const char* cstrTopic = [willTopic cStringUsingEncoding:NSUTF8StringEncoding];
    mosquitto_will_set(mosq, cstrTopic, payload.length, payload.bytes, willQos, retain);
}

- (void)setWill:(NSString *)payload toTopic:(NSString *)willTopic withQos:(NSUInteger)willQos retain:(BOOL)retain;
{
    [self setWillData:[payload dataUsingEncoding:NSUTF8StringEncoding]
              toTopic:willTopic
              withQos:willQos
               retain:retain];
}

- (void)clearWill
{
    mosquitto_will_clear(mosq);
}

- (void)publishData:(NSData *)payload toTopic:(NSString *)topic withQos:(NSUInteger)qos retain:(BOOL)retain {
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    mosquitto_publish(mosq, NULL, cstrTopic, payload.length, payload.bytes, qos, retain);
}
- (void)publishString: (NSString *)payload toTopic:(NSString *)topic withQos:(NSUInteger)qos retain:(BOOL)retain {
    [self publishData:[payload dataUsingEncoding:NSUTF8StringEncoding]
              toTopic:topic
              withQos:qos
               retain:retain];
}

- (void)subscribe: (NSString *)topic {
    [self subscribe:topic withQos:0];
}

- (void)subscribe: (NSString *)topic withQos:(NSUInteger)qos {
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    mosquitto_subscribe(mosq, NULL, cstrTopic, qos);
}

- (void)unsubscribe: (NSString *)topic {
    const char* cstrTopic = [topic cStringUsingEncoding:NSUTF8StringEncoding];
    mosquitto_unsubscribe(mosq, NULL, cstrTopic);
}


- (void) setMessageRetry: (NSUInteger)seconds
{
    mosquitto_message_retry_set(mosq, (unsigned int)seconds);
}

- (void) dealloc {
    if (mosq) {
        mosquitto_destroy(mosq);
        mosq = NULL;
    }
}

@end

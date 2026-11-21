#import "Keychain.h"
#import <Security/Security.h>

static NSString* const kService = @"app.dalny.client";
static NSString* const kErrorDomain = @"app.dalny.client.keychain";

#ifndef errSecMissingEntitlement
#define errSecMissingEntitlement ((OSStatus)-34018)
#endif

@implementation Keychain

+ (NSError*)errorForStatus:(OSStatus)status action:(NSString*)action legacy:(BOOL)legacy
{
	NSString* message = (__bridge_transfer NSString*)SecCopyErrorMessageString(status, NULL);
	NSString* where = legacy ? @"обычная связка ключей" : @"связка защиты данных";
	NSString* text = [NSString stringWithFormat:@"%@ не удалось (%@): %@ (OSStatus %d)", action, where,
	                                            message ?: @"без текста", (int)status];
	return [NSError errorWithDomain:kErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey : text}];
}

+ (NSMutableDictionary*)queryForAccount:(NSString*)account dataProtection:(BOOL)dataProtection
{
	NSMutableDictionary* query = [@{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService : kService,
		(__bridge id)kSecAttrAccount : account
	} mutableCopy];
	if (dataProtection)
		query[(__bridge id)kSecUseDataProtectionKeychain] = @YES;
	return query;
}

+ (BOOL)statusAllowsLegacyFallback:(OSStatus)status
{
	return status == errSecMissingEntitlement || status == errSecParam;
}

+ (OSStatus)deleteAccount:(NSString*)account dataProtection:(BOOL)dataProtection
{
	NSDictionary* query = [self queryForAccount:account dataProtection:dataProtection];
	OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
	if (status == errSecItemNotFound)
		return errSecSuccess;
	return status;
}

+ (OSStatus)addSecret:(NSString*)secret account:(NSString*)account dataProtection:(BOOL)dataProtection
{
	[self deleteAccount:account dataProtection:dataProtection];
	if (secret.length == 0)
		return errSecSuccess;
	NSMutableDictionary* query = [self queryForAccount:account dataProtection:dataProtection];
	query[(__bridge id)kSecValueData] = [secret dataUsingEncoding:NSUTF8StringEncoding];
	if (dataProtection)
		query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
	else
		query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlocked;
	return SecItemAdd((__bridge CFDictionaryRef)query, NULL);
}

+ (NSString*)copySecretForAccount:(NSString*)account dataProtection:(BOOL)dataProtection status:(OSStatus*)status
{
	NSMutableDictionary* query = [self queryForAccount:account dataProtection:dataProtection];
	query[(__bridge id)kSecReturnData] = @YES;
	query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
	CFTypeRef result = NULL;
	OSStatus code = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	if (status)
		*status = code;
	if (code != errSecSuccess || !result)
		return nil;
	NSData* data = CFBridgingRelease(result);
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)setSecret:(NSString*)secret account:(NSString*)account error:(NSError**)error
{
	if (account.length == 0)
	{
		if (error)
			*error = [NSError errorWithDomain:kErrorDomain
			                             code:errSecParam
			                         userInfo:@{NSLocalizedDescriptionKey : @"Пустой идентификатор записи Связки ключей."}];
		return NO;
	}
	OSStatus status = [self addSecret:secret account:account dataProtection:YES];
	BOOL legacy = NO;
	if ([self statusAllowsLegacyFallback:status])
	{
		legacy = YES;
		status = [self addSecret:secret account:account dataProtection:NO];
	}
	if (status != errSecSuccess)
	{
		if (error)
			*error = [self errorForStatus:status action:@"Запись секрета" legacy:legacy];
		return NO;
	}
	if (secret.length == 0)
		return YES;

	NSError* readError = nil;
	NSString* stored = [self secretForAccount:account error:&readError];
	if (![stored isEqualToString:secret])
	{
		if (error)
		{
			*error = readError
			             ?: [NSError errorWithDomain:kErrorDomain
			                                    code:errSecInternalError
			                                userInfo:@{
				                                NSLocalizedDescriptionKey :
				                                    @"Связка ключей записала секрет, но прочитать его обратно не удалось."
			                                }];
		}
		return NO;
	}
	return YES;
}

+ (NSString*)secretForAccount:(NSString*)account error:(NSError**)error
{
	if (account.length == 0)
		return nil;
	OSStatus status = errSecSuccess;
	NSString* secret = [self copySecretForAccount:account dataProtection:YES status:&status];
	if (status == errSecSuccess)
		return secret;
	if (status != errSecItemNotFound && ![self statusAllowsLegacyFallback:status])
	{
		if (error)
			*error = [self errorForStatus:status action:@"Чтение секрета" legacy:NO];
		return nil;
	}
	OSStatus legacyStatus = errSecSuccess;
	secret = [self copySecretForAccount:account dataProtection:NO status:&legacyStatus];
	if (legacyStatus == errSecSuccess)
		return secret;
	if (legacyStatus == errSecItemNotFound && (status == errSecItemNotFound || [self statusAllowsLegacyFallback:status]))
		return nil;
	if (error)
		*error = [self errorForStatus:legacyStatus action:@"Чтение секрета" legacy:YES];
	return nil;
}

+ (BOOL)deleteAccount:(NSString*)account error:(NSError**)error
{
	if (account.length == 0)
		return YES;
	OSStatus modern = [self deleteAccount:account dataProtection:YES];
	OSStatus legacy = [self deleteAccount:account dataProtection:NO];
	if (modern != errSecSuccess && ![self statusAllowsLegacyFallback:modern])
	{
		if (error)
			*error = [self errorForStatus:modern action:@"Удаление секрета" legacy:NO];
		return NO;
	}
	if (legacy != errSecSuccess)
	{
		if (error)
			*error = [self errorForStatus:legacy action:@"Удаление секрета" legacy:YES];
		return NO;
	}
	return YES;
}

@end

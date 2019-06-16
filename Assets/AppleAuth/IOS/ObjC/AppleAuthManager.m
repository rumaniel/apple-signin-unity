//
//  MIT License
//
//  Copyright (c) 2019 Daniel Lupiañez Casares
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "AppleAuthManager.h"
#import "NativeMessageHandler.h"
#import "AppleAuthSerializer.h"

#pragma mark - iOS 13.0/macOS 13.0 Implementation

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 || __TV_OS_VERSION_MAX_ALLOWED >= 130000 || __MAC_OS_X_VERSION_MAX_ALLOWED >= 101500
#import <AuthenticationServices/AuthenticationServices.h>

@interface AppleAuthManager () <ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding>
@property (nonatomic, strong) ASAuthorizationAppleIDProvider *appleIdProvider;
@property (nonatomic, strong) ASAuthorizationPasswordProvider *passwordProvider;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSNumber *> *authorizationsInProgress;
@end

@implementation AppleAuthManager

+ (instancetype) sharedManager
{
    static AppleAuthManager *_defaultManager = nil;
    static dispatch_once_t defaultManagerInitialization;
    
    dispatch_once(&defaultManagerInitialization, ^{
        _defaultManager = [[AppleAuthManager alloc] init];
    });
    
    return _defaultManager;
}

- (instancetype) init
{
    self = [super init];
    if (self)
    {
        _appleIdProvider = [[ASAuthorizationAppleIDProvider alloc] init];
        _passwordProvider = [[ASAuthorizationPasswordProvider alloc] init];
        _authorizationsInProgress = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark Public methods

- (void) loginSilently:(uint)requestId
{
    ASAuthorizationAppleIDRequest *appleIDSilentRequest = [[self appleIdProvider] createRequest];
    ASAuthorizationPasswordRequest *passwordSilentRequest = [[self passwordProvider] createRequest];
    
    ASAuthorizationController *authorizationController = [[ASAuthorizationController alloc] initWithAuthorizationRequests:@[appleIDSilentRequest, passwordSilentRequest]];
    [self performAuthorizationRequestsForController:authorizationController withRequestId:requestId];
}

- (void) loginWithAppleId:(uint)requestId withOptions:(AppleAuthManagerLoginOptions)options
{
    ASAuthorizationAppleIDRequest *request = [[self appleIdProvider] createRequest];
    NSMutableArray *scopes = [NSMutableArray array];
    
    if (options & AppleAuthManagerIncludeName)
        [scopes addObject:ASAuthorizationScopeFullName];
        
    if (options & AppleAuthManagerIncludeEmail)
        [scopes addObject:ASAuthorizationScopeEmail];
        
    [request setRequestedScopes:[scopes copy]];
    
    ASAuthorizationController *authorizationController = [[ASAuthorizationController alloc] initWithAuthorizationRequests:@[request]];
    [self performAuthorizationRequestsForController:authorizationController withRequestId:requestId];
}


- (void) getCredentialStateForUser:(NSString *)userId withRequestId:(uint)requestId
{
    [[self appleIdProvider] getCredentialStateForUserID:userId completion:^(ASAuthorizationAppleIDProviderCredentialState credentialState, NSError * _Nullable error) {
        NSNumber *credentialStateNumber = nil;
        NSDictionary *errorDictionary = nil;
        
        if (error)
            errorDictionary = [AppleAuthManager dictionaryForNSError:error];
        else
            credentialStateNumber = @(credentialState);
        
        NSDictionary *responseDictionary = [AppleAuthManager credentialResponseDictionaryForCredentialState:credentialStateNumber
                                                                                            errorDictionary:errorDictionary];
        
        [self sendNativeMessage:responseDictionary withRequestId:requestId];
    }];
}

#pragma mark Private methods

- (void) performAuthorizationRequestsForController:(ASAuthorizationController *)authorizationController withRequestId:(uint)requestId
{
    NSValue *authControllerAsKey = [NSValue valueWithNonretainedObject:authorizationController];
    [[self authorizationsInProgress] setObject:@(requestId) forKey:authControllerAsKey];
    
    [authorizationController setDelegate:self];
    [authorizationController setPresentationContextProvider:self];
    [authorizationController performRequests];
}

#pragma mark ASAuthorizationControllerDelegate protocol implementation

- (void) authorizationController:(ASAuthorizationController *)controller didCompleteWithAuthorization:(ASAuthorization *)authorization
{
    NSValue *authControllerAsKey = [NSValue valueWithNonretainedObject:controller];
    NSNumber *requestIdNumber = [[self authorizationsInProgress] objectForKey:authControllerAsKey];
    if (requestIdNumber)
    {
        NSDictionary *appleIdCredentialDictionary = nil;
        NSDictionary *passwordCredentialDictionary = nil;
        if ([[authorization credential] isKindOfClass:[ASAuthorizationAppleIDCredential class]])
        {
            appleIdCredentialDictionary = [AppleAuthManager dictionaryForASAuthorizationAppleIDCredential:(ASAuthorizationAppleIDCredential *)[authorization credential]];
        }
        else if ([[authorization credential] isKindOfClass:[ASPasswordCredential class]])
        {
            passwordCredentialDictionary = [AppleAuthManager dictionaryForASPasswordCredential:(ASPasswordCredential *)[authorization credential]];
        }

        NSDictionary *responseDictionary = [AppleAuthManager loginResponseDictionaryForAppleIdCredentialDictionary:appleIdCredentialDictionary
                                                                                      passwordCredentialDictionary:passwordCredentialDictionary
                                                                                                   errorDictionary:nil];
        
        [self sendNativeMessage:responseDictionary withRequestId:[requestIdNumber unsignedIntValue]];
        [[self authorizationsInProgress] removeObjectForKey:authControllerAsKey];
    }
}

- (void) authorizationController:(ASAuthorizationController *)controller didCompleteWithError:(NSError *)error
{
    NSValue *authControllerAsKey = [NSValue valueWithNonretainedObject:controller];
    NSNumber *requestIdNumber = [[self authorizationsInProgress] objectForKey:authControllerAsKey];
    if (requestIdNumber)
    {
        NSDictionary *errorDictionary = [AppleAuthManager dictionaryForNSError:error];
        NSDictionary *responseDictionary = [AppleAuthManager loginResponseDictionaryForAppleIdCredentialDictionary:nil
                                                                                      passwordCredentialDictionary:nil
                                                                                                   errorDictionary:errorDictionary];
        
        [self sendNativeMessage:responseDictionary withRequestId:[requestIdNumber unsignedIntValue]];
        [[self authorizationsInProgress] removeObjectForKey:authControllerAsKey];
    }
}

#pragma mark ASAuthorizationControllerPresentationContextProviding protocol implementation

- (ASPresentationAnchor) presentationAnchorForAuthorizationController:(ASAuthorizationController *)controller
{
    return [[[UIApplication sharedApplication] delegate] window];
}

@end

#pragma mark Native C Calls for working implementation

bool AppleAuth_IOS_IsCurrentPlatformSupported()
{
    return true;
}

void AppleAuth_IOS_GetCredentialState(uint requestId, const char* userId)
{
    [[AppleAuthManager sharedManager] getCredentialStateForUser:[NSString stringWithUTF8String:userId] withRequestId:requestId];
}

void AppleAuth_IOS_LoginWithAppleId(uint requestId, int options)
{
    [[AppleAuthManager sharedManager] loginWithAppleId:requestId withOptions:options];
}

void AppleAuth_IOS_LoginSilently(uint requestId)
{
    [[AppleAuthManager sharedManager] loginSilently:requestId];
}
#else

#pragma mark - Lower iOS/macOS Implementation
#pragma mark Native C Calls for working implementation

bool AppleAuth_IOS_IsCurrentPlatformSupported()
{
    return false;
}

void AppleAuth_IOS_GetCredentialState(uint requestId, const char* userId)
{
    NSError *customError = [NSError errorWithDomain:@"com.unity.AppleAuth" code:-100 userInfo:nil];
    NSDictionary *customErrorDictionary = [AppleAuthSerializer dictionaryForNSError:customError];
    NSDictionary *responseDictionary = [AppleAuthSerializer credentialResponseDictionaryForCredentialState:nil
                                                                                           errorDictionary:customErrorDictionary];
    
    [[NativeMessageHandler defaultHandler] sendNativeMessageForDictionary:responseDictionary forRequestId:requestId];
}

void AppleAuth_IOS_LoginWithAppleId(uint requestId, int options)
{
    NSError *customError = [NSError errorWithDomain:@"com.unity.AppleAuth" code:-100 userInfo:nil];
    NSDictionary *customErrorDictionary = [AppleAuthSerializer dictionaryForNSError:customError];
    NSDictionary *responseDictionary = [AppleAuthSerializer loginResponseDictionaryForAppleIdCredentialDictionary:nil
                                                                                     passwordCredentialDictionary:nil
                                                                                                  errorDictionary:customErrorDictionary];
    
    [[NativeMessageHandler defaultHandler] sendNativeMessageForDictionary:responseDictionary forRequestId:requestId];
}

void AppleAuth_IOS_LoginSilently(uint requestId)
{
    NSError *customError = [NSError errorWithDomain:@"com.unity.AppleAuth" code:-100 userInfo:nil];
    NSDictionary *customErrorDictionary = [AppleAuthSerializer dictionaryForNSError:customError];
    NSDictionary *responseDictionary = [AppleAuthSerializer loginResponseDictionaryForAppleIdCredentialDictionary:nil
                                                                                     passwordCredentialDictionary:nil
                                                                                                  errorDictionary:customErrorDictionary];
    
    [[NativeMessageHandler defaultHandler] sendNativeMessageForDictionary:responseDictionary forRequestId:requestId];
}

#endif

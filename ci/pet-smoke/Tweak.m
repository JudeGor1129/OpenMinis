#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void PetSmokeInitialize(void) {
    @autoreleasepool {
        NSLog(@"[PetSmoke] embedded Theos dual-slice probe loaded");
    }
}

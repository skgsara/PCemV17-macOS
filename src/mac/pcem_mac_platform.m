/* See pcem_mac_platform.h for why this file exists (Foundation vs. PCem's
 * thread_create/pause name collisions). No PCem core headers in here. */
#import <Foundation/Foundation.h>
#include <string.h>
#include <stdlib.h>

#include "pcem_mac_platform.h"

void pcem_mac_data_path(char *s, int size)
{
        snprintf(s, size, "%s/.pcem/", [NSHomeDirectory() fileSystemRepresentation]);
}

void pcem_mac_ensure_data_dirs(void)
{
        char base[1024];
        pcem_mac_data_path(base, sizeof(base));
        NSString *baseNS = [NSString stringWithUTF8String:base];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *sub in @[ @".", @"roms", @"nvr", @"configs", @"screenshots" ])
        {
                NSString *dir = [baseNS stringByAppendingPathComponent:sub];
                [fm createDirectoryAtPath:dir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        }
}

int pcem_mac_list_configs(const char *dir, char ***names_out)
{
        *names_out = NULL;

        NSString *dirNS = [NSString stringWithUTF8String:dir];
        NSArray *files = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:dirNS error:nil];
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *f in files)
        {
                if ([[f pathExtension] isEqualToString:@"cfg"])
                        [names addObject:[f stringByDeletingPathExtension]];
        }
        [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

        int count = (int)[names count];
        char **out = malloc(sizeof(char *) * (count ? count : 1));
        for (int i = 0; i < count; i++)
                out[i] = strdup([[names objectAtIndex:i] UTF8String]);
        *names_out = out;
        return count;
}

void pcem_mac_log(const char *msg)
{
        NSLog(@"%s", msg);
}

void pcem_mac_run_on_main(void (*fn)(void *), void *ctx)
{
        dispatch_async_f(dispatch_get_main_queue(), ctx, fn);
}

void pcem_mac_defaults_set_string(const char *key, const char *value)
{
        [[NSUserDefaults standardUserDefaults]
                setObject:[NSString stringWithUTF8String:value]
                   forKey:[NSString stringWithUTF8String:key]];
}

int pcem_mac_defaults_get_string(const char *key, char *buf, int size)
{
        NSString *val = [[NSUserDefaults standardUserDefaults]
                         stringForKey:[NSString stringWithUTF8String:key]];
        if (!val)
                return 0;
        snprintf(buf, size, "%s", [val UTF8String]);
        return 1;
}

void pcem_mac_defaults_remove(const char *key)
{
        [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:[NSString stringWithUTF8String:key]];
}


#ifndef XCBIMDKIT_EXPORT_H
#define XCBIMDKIT_EXPORT_H

#ifdef XCBIMDKIT_STATIC_DEFINE
#  define XCBIMDKIT_EXPORT
#  define XCBIMDKIT_NO_EXPORT
#else
#  ifndef XCBIMDKIT_EXPORT
#    ifdef xcb_imdkit_EXPORTS
        /* We are building this library */
#      define XCBIMDKIT_EXPORT __attribute__((visibility("default")))
#    else
        /* We are using this library */
#      define XCBIMDKIT_EXPORT __attribute__((visibility("default")))
#    endif
#  endif

#  ifndef XCBIMDKIT_NO_EXPORT
#    define XCBIMDKIT_NO_EXPORT __attribute__((visibility("hidden")))
#  endif
#endif

#ifndef XCBIMDKIT_DEPRECATED
#  define XCBIMDKIT_DEPRECATED __attribute__ ((__deprecated__))
#endif

#ifndef XCBIMDKIT_DEPRECATED_EXPORT
#  define XCBIMDKIT_DEPRECATED_EXPORT XCBIMDKIT_EXPORT XCBIMDKIT_DEPRECATED
#endif

#ifndef XCBIMDKIT_DEPRECATED_NO_EXPORT
#  define XCBIMDKIT_DEPRECATED_NO_EXPORT XCBIMDKIT_NO_EXPORT XCBIMDKIT_DEPRECATED
#endif

#if 0 /* DEFINE_NO_DEPRECATED */
#  ifndef XCBIMDKIT_NO_DEPRECATED
#    define XCBIMDKIT_NO_DEPRECATED
#  endif
#endif

#endif /* XCBIMDKIT_EXPORT_H */

/* Export macros for the k4arecord API: nothing to export on macOS, where the
 * library is linked statically or as a plain dylib. */
#ifndef K4ARECORD_EXPORT_H
#define K4ARECORD_EXPORT_H

#if defined(K4A_STATIC_DEFINE) || !defined(_WIN32)
#  define K4ARECORD_EXPORT
#  define K4ARECORD_NO_EXPORT
#  ifndef K4ARECORD_DEPRECATED
#    define K4ARECORD_DEPRECATED
#  endif
#else
#  ifndef K4ARECORD_EXPORT
#    ifdef k4arecord_EXPORTS
#      define K4ARECORD_EXPORT __declspec(dllexport)
#    else
#      define K4ARECORD_EXPORT __declspec(dllimport)
#    endif
#  endif
#  ifndef K4ARECORD_NO_EXPORT
#    define K4ARECORD_NO_EXPORT
#  endif
#  ifndef K4ARECORD_DEPRECATED
#    define K4ARECORD_DEPRECATED __declspec(deprecated)
#  endif
#endif

#ifndef K4ARECORD_DEPRECATED_EXPORT
#  define K4ARECORD_DEPRECATED_EXPORT K4ARECORD_EXPORT K4ARECORD_DEPRECATED
#endif

#endif /* K4ARECORD_EXPORT_H */

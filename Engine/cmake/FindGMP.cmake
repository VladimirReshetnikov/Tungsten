# Locate the GNU Multiple Precision C and C++ libraries.
#
# Defines:
#   GMP_FOUND
#   GMP_INCLUDE_DIR
#   GMP_LIBRARY
#   GMPXX_LIBRARY
#   GMP::gmp
#   GMP::gmpxx

find_path(GMP_INCLUDE_DIR NAMES gmpxx.h)
find_library(GMP_LIBRARY NAMES gmp libgmp gmp-10)
find_library(GMPXX_LIBRARY NAMES gmpxx libgmpxx gmpxx-4)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(
    GMP
    REQUIRED_VARS GMP_INCLUDE_DIR GMP_LIBRARY GMPXX_LIBRARY)

if(GMP_FOUND AND NOT TARGET GMP::gmp)
    add_library(GMP::gmp UNKNOWN IMPORTED)
    set_target_properties(
        GMP::gmp
        PROPERTIES
            IMPORTED_LOCATION "${GMP_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${GMP_INCLUDE_DIR}")
endif()

if(GMP_FOUND AND NOT TARGET GMP::gmpxx)
    add_library(GMP::gmpxx UNKNOWN IMPORTED)
    set_target_properties(
        GMP::gmpxx
        PROPERTIES
            IMPORTED_LOCATION "${GMPXX_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${GMP_INCLUDE_DIR}"
            INTERFACE_LINK_LIBRARIES GMP::gmp)
endif()

mark_as_advanced(GMP_INCLUDE_DIR GMP_LIBRARY GMPXX_LIBRARY)

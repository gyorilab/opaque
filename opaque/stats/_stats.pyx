import cython
import numpy as np
from libc.math cimport pow as cpow
from libc.math cimport fabs, exp, log, log1p, pi, sqrt
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.pycapsule cimport PyCapsule_GetPointer, PyCapsule_IsValid

from numpy.random import PCG64
from numpy.random cimport bitgen_t
from numpy.random.c_distributions cimport random_beta

from scipy.optimize.cython_optimize cimport brentq
from scipy.special.cython_special cimport loggamma


@cython.cdivision(True)
cdef double gamma_star(double a):
    """Scaled Gamma Function

    The Gamma function divided by Stirling's approximation
    """
    cdef double log_output
    if a == 0:
        return float('inf')
    elif a < 8:
        log_output = (loggamma(a) + a - 0.5*log(2*pi) -
                      (a - 0.5)*log(a))
        return exp(log_output)
    else:
        # Use Neme's approximation for sufficiently large input
        return cpow((1 + 1/(12*cpow(a, 2) - 1/10)), a)


@cython.cdivision(True)
cdef double D(double p, double q, double x):
    cdef double part1, part2, x0, sigma, tau
    if x == 0 or x == 1:
        return 0.0
    part1 = sqrt(p*q/(2*pi*(p+q))) * \
        gamma_star(p+q)/(gamma_star(p)*gamma_star(q))
    x0 = p/(p+q)
    sigma = (x - x0)/x0
    tau = (x0 - x)/(1 - x0)
    part2 = exp(p*(log1p(sigma) - sigma) + q*(log1p(tau) - tau))
    return part1 * part2


@cython.cdivision(True)
cdef inline double coefficient(int n, double p, double q, double x):
    cdef int m
    m = n // 2
    if n % 2 == 0:
        return m*(q-m)/((p+2*m-1)*(p+2*m)) * x
    else:
        return -(p+m)*(p+q+m)/((p+2*m)*(p+2*m+1)) * x


@cython.cdivision(True)
cdef double K(double p, double q, double x, double tol=1e-12):
    cdef int n
    cdef double delC, C, D
    delC = coefficient(1, p, q, x)
    C, D = 1 + delC, 1
    n = 2
    while fabs(delC) > tol:
        D = 1/(D*coefficient(n, p, q, x) + 1)
        delC *= (D - 1)
        C += delC
        n += 1
    return 1/C


@cython.cdivision(True)
cdef double betainc(float p, float q, float x):
    if x > p/(p+q):
        return 1 - betainc(q, p, 1-x)
    else:
        return D(p, q, x)/p * K(p, q, x)


cdef double prevalence_cdf_exact(double theta, int n, int t,
                                 double sensitivity,
                                 double specificity):
    cdef double c1, c2, numerator, denominator
    c1, c2 = 1 - specificity, sensitivity + specificity - 1
    numerator = (betainc(t+1, n-t+1, c1 + c2*theta) - betainc(t+1, n-t+1, c1))
    denominator = betainc(t+1, n-t+1, c1 + c2) - betainc(t+1, n-t+1, c1)
    if denominator == 0:
        return theta
    return numerator/denominator


cdef double prevalence_cdf(double theta, int n, int t,
                           double sens_a, double sens_b,
                           double spec_a, double spec_b,
                           int num_samples):
    cdef int i
    cdef bitgen_t *rng
    cdef const char *capsule_name = "BitGenerator"
    cdef double result
    cdef double *sens_array
    cdef double *spec_array

    sens_array = <double *> PyMem_Malloc(num_samples * sizeof(double))
    spec_array = <double *> PyMem_Malloc(num_samples * sizeof(double))
    
    x = PCG64()
    capsule = x.capsule
    if not PyCapsule_IsValid(capsule, capsule_name):
        raise ValueError("Invalid pointer to anon_func_state")
    rng = <bitgen_t *> PyCapsule_GetPointer(capsule, capsule_name)

    i = 0
    with x.lock, nogil:
        for i in range(num_samples):
            sens_array[i] = random_beta(rng, sens_a, sens_b)
            spec_array[i] = random_beta(rng, spec_a, spec_b)
    result = 0
    i = 0
    for i in range(num_samples):
        result += prevalence_cdf_exact(theta, n, t, sens_array[i],
                                       spec_array[i])
    PyMem_Free(sens_array)
    PyMem_Free(spec_array)
    return result/num_samples


ctypedef struct inverse_cdf_params:
    int n
    int t
    int num_samples
    double sens_a
    double sens_b
    double spec_a
    double spec_b
    double val


@cython.cdivision(True)
cdef double f(double theta, void *args):
    cdef inverse_cdf_params *params = <inverse_cdf_params *> args
    return prevalence_cdf(theta, params.n, params.t,
                          params.sens_a, params.sens_b,
                          params.spec_a, params.spec_b,
                          params.num_samples) - params.val


cdef double inverse_cdf(double x, int n, int t, double sens_a, double sens_b,
                        double spec_a, double spec_b,
                        int num_samples):
    cdef inverse_cdf_params args
    args.n, args.t = n, t
    args.sens_a, args.sens_b = sens_a, sens_b
    args.spec_a, args.spec_b = spec_a, spec_b
    args.val, args.num_samples = x, num_samples
    return brentq(f, 0, 1, &args, 1e-3, 1e-3, 100, NULL)


cdef double interval_width(double x, void *args):
    cdef inverse_cdf_params *params = <inverse_cdf_params *> args
    cdef double left, right
    left = inverse_cdf(x, params.n, params.t,
                       params.sens_a, params.sens_b,
                       params.spec_a, params.spec_b,
                       params.num_samples)
    right = inverse_cdf(x + params.val, params.n, params.t,
                        params.sens_a, params.sens_b,
                        params.spec_a, params.spec_b,
                        params.num_samples)
    return right - left


ctypedef double (*function_1d)(double, void*)


cdef (double, double) golden_section_search(function_1d func, double left,
                                            double right, double x_tol,
                                            double y_tol,
                                            void *args):
    """Returns a minimum obtained by func over the interval (left, right)

    Returns the minimum value of f(x), contrary to the typical practice
    of returning the value x at which the minimum is obtained. Guaranteed
    to be a global minimum if f is unimodal.
    """
    cdef double x1, x2, x3, x4
    cdef double func_at_x2, func_at_x3
    cdef double inv_phi = (sqrt(5) - 1) / 2

    x1, x4 = left, right
    x2, x3 = x4 - (x4 - x1) * inv_phi, x1 + (x4 - x1) * inv_phi
    func_at_x2, func_at_x3 = func(x2, args), func(x3, args)
    while True:
        if func_at_x2 < func_at_x3:
            x3, x4 = x2, x3
            if fabs(x4 - x1) < x_tol and fabs(func_at_x2 - func_at_x3) < y_tol:
                return x2, func_at_x2
            func_at_x3 = func_at_x2
            x2 = x4 - (x4 - x1) * inv_phi
            func_at_x2 = func(x2, args)
        else:
            x1, x2 = x2, x3
            if fabs(x4 - x1) < x_tol and fabs(func_at_x2 - func_at_x3) < y_tol:
                return x3, func_at_x3
            func_at_x2 = func_at_x3
            x3 = x1 + (x4 - x1) * inv_phi
            func_at_x3 = func(x3, args)


def highest_density_interval(n, t, sens_a, sens_b, spec_a, spec_b,
                             alpha, num_samples=5000):
    cdef double left, right
    cdef double argmin, min_
    cdef inverse_cdf_params args
    args.n, args.t = n, t
    args.sens_a, args.sens_b = sens_a, sens_b
    args.spec_a, args.spec_b = spec_a, spec_b
    args.val, args.num_samples = 1 - alpha, num_samples

    argmin_width, min_width = golden_section_search(interval_width, 0, alpha,
                                                    0.001, 0.01, &args)
    left = inverse_cdf(argmin_width, n, t, sens_a, sens_b, spec_a, spec_b,
                       num_samples)
    right = left + min_width
    return (max(0.0, left), min(right, 1.0))


def equal_tailed_interval(n, t, sens_a, sens_b, spec_a, spec_b,
                          alpha, num_samples=5000):
    return (inverse_cdf(alpha/2, n, t, sens_a, sens_b, spec_a, spec_b,
                        num_samples),
            inverse_cdf(1 - alpha/2, n, t, sens_a, sens_b, spec_a, spec_b,
                        num_samples))

defmodule Axon.Updates do
  @moduledoc """
  Parameter update methods.

  Update methods transform the input tensor in some way,
  usually by scaling or shifting the input with respect
  to some input state. Update methods are typically composed
  to create more advanced optimization methods such as AdaGrad
  or Adam; however, they can also be applied to model parameters.

  These methods are the building blocks of common gradient descent
  methods. For example, a basic gradient descent algorithm
  would look something like:

      g_param = grad(param, loss_fun(...))
      param - 0.01 * g_param

  With these methods, you can write that as:

      g_param = grad(param, loss_fun(...))
      param + scale(g_param, step: -0.01)

  The benefits of this module are more easily seen as optimizers
  get more complex. For example, you can implement the Adam optimizer:

      g_param = grad(param, loss_fun(...))
      {updates, mu_new, nu_new} =
        g_param
        |> scale_by_adam(mu, nu)

      g_param + scale(updates, step: -0.01)

  In the example above, by `mu` and `nu` are the 1st and 2nd moment
  respectively. Normally, they would be initialized and maintained
  as optimizer parameters; however, because these are stateless
  implementations, they are updated along with the input updates.

  All of the functions in this module are implemented as
  numerical functions and can be JIT or AOT compiled with
  any supported `Nx` compiler.

  """
  import Nx.Defn
  import Axon.Shared

  @doc ~S"""
  Scales input by a fixed step size.

  $$f(x_i) = \alpha x_i$$

  ## Options

      * `:step` - step size. $alpha$ in the above formulation.

  ## Examples

      iex> Axon.Updates.scale(Nx.tensor([-1.0, 0.0, 1.0]), step: 0.01)
      #Nx.Tensor<
        f64[3]
        [-0.01, 0.0, 0.01]
      >

      iex> Axon.Updates.scale(Nx.tensor([[-5, 2, 1, 4, 2], [0, 2, 1, 4, 1]]), step: 0.1)
      #Nx.Tensor<
        f64[2][5]
        [
          [-0.5, 0.2, 0.1, 0.4, 0.2],
          [0.0, 0.2, 0.1, 0.4, 0.1]
        ]
      >

  """
  defn scale(x, opts \\ []) do
    opts = keyword!(opts, [:step])

    x
    |> Nx.multiply(opts[:step])
  end

  @doc """
  Scales input according to Adam algorithm.

  Returns `{scaled_input, updated_mu, update_nu}`.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`
      * `:eps_root` - numerical stability term. Defaults to `0.0`

  ## References

    * [Adam: A Method for Stochastic Optimization](https://arxiv.org/abs/1412.6980)

  """
  defn scale_by_adam(x, mu, nu, count, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 1.0e-8, eps_root: 0.0)
    mu = update_moment(x, mu, opts[:b1], 1)
    nu = update_moment(x, nu, opts[:b2], 2)
    mu_hat = bias_correction(mu, opts[:b1], count + 1)
    nu_hat = bias_correction(nu, opts[:b2], count + 1)

    x = Nx.divide(mu_hat, Nx.sqrt(nu_hat + opts[:eps_root]) + opts[:eps])
    {x, mu, nu}
  end

  @doc """
  Scales input by the root of all prior squared inputs.

  Returns `{scaled_input, updated_sum_of_squares}`.

  ## Options

      * `:eps` - numerical stability term. Defaults to `1.0e-7`

  """
  defn scale_by_rss(x, sum_of_squares, opts \\ []) do
    opts = keyword!(opts, eps: 1.0e-7)
    sum_of_squares = Nx.power(x, 2) + sum_of_squares

    inv_sqrt_x_square =
      Nx.select(Nx.greater(sum_of_squares, 0), Nx.rsqrt(sum_of_squares + opts[:eps]), 0.0)

    x = inv_sqrt_x_square * x

    {x, sum_of_squares}
  end

  @doc """
  Scales input by the root of the EMA of squared inputs.

  Returns `{scaled_input, updated_nu}`

  ## Options

      * `:decay` - EMA decay rate. Defaults to `0.9`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`

  ## References

    * [Overview of mini-batch gradient descent](www.cs.toronto.edu/~tijmen/csc321/slides/lecture_slides_lec6.pdf)

  """
  defn scale_by_rms(x, nu, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, eps: 1.0e-8)
    nu = update_moment(x, nu, opts[:decay], 2)

    x = x * Nx.rsqrt(nu + opts[:eps])

    {x, nu}
  end

  @doc """
  Scales input according to the AdaBelief algorithm.

  Returns `{scaled_input, update_mu, updated_nu}`.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `0.0`
      * `:eps_root` - numerical stability term. Defaults to `1.0e-16`

  ## References

    * [AdaBelief Optimizer: Adapting Stepsizes by the Belief in Observed Gradients](https://arxiv.org/abs/2010.07468)

  """
  defn scale_by_belief(x, mu, nu, count, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 0.0, eps_root: 1.0e-16)
    mu = update_moment(x, mu, opts[:b1], 1)
    pred_error = x - mu
    nu = update_moment(pred_error, nu, opts[:b2], 2)
    mu_hat = bias_correction(mu, opts[:b1], count + 1)
    nu_hat = bias_correction(nu, opts[:b2], count + 1)

    x = Nx.divide(mu_hat, Nx.sqrt(nu_hat + opts[:eps_root]) + opts[:eps])

    {x, mu, nu}
  end

  @doc """
  Scales input by the root of the centered EMA of squared inputs.

  Returns `{scaled_input, updated_mu, updated_nu}`

  ## Options

      * `:decay` - EMA decay rate. Defaults to `0.9`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`

  ## References

    * [Overview of mini-batch gradient descent](www.cs.toronto.edu/~tijmen/csc321/slides/lecture_slides_lec6.pdf)

  """
  defn scale_by_stddev(x, mu, nu, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, eps: 1.0e-8)
    mu = update_moment(x, mu, opts[:decay], 1)
    nu = update_moment(x, nu, opts[:decay], 2)

    x = x * Nx.rsqrt(nu - Nx.power(mu, 2) + opts[:eps])

    {x, mu, nu}
  end

  @doc """
  Scales input using the given schedule function.
  """
  def scale_by_schedule(x, count, schedule_fn) when is_function(schedule_fn) do
    step_size = schedule_fn.(count)
    Nx.multiply(x, step_size)
  end

  @doc """
  Scales input by trust ratio.

  Returns `scaled_input`.

  ## Options

      * `:min_norm` - minimum norm for inputs. Defaults to `0.0`

  ## References

      [Large Batch Optimization for Deep Learning: Training BERT in 76 minutes](https://arxiv.org/abs/1904.00962)

  """
  defn scale_by_trust_ratio(x, g, opts \\ []) do
    opts = keyword!(opts, min_norm: 0.0)
    param_norm = safe_norm(x, opts[:min_norm])
    update_norm = safe_norm(g, opts[:min_norm])
    trust_ratio = Nx.divide(param_norm, update_norm)

    zero_norm = Nx.logical_or(Nx.equal(param_norm, 0), Nx.equal(update_norm, 0))

    safe_trust_ratio = Nx.select(zero_norm, 1, trust_ratio)

    Nx.multiply(x, safe_trust_ratio)
  end

  @doc """
  Scale input according to the Rectified Adam algorithm.

  Returns `{scaled_input, updated_mu, updated_nu}`.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`
      * `:eps_root` - numerical stability term. Defaults to `0.0`
      * `:threshold` - threshold for variance. Defaults to `5.0`

  ## References

    * [On the Variance of the Adaptive Learning Rate and Beyond](https://arxiv.org/abs/1908.03265)

  """
  defn scale_by_radam(x, mu, nu, count, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 1.0e-8, eps_root: 0.0, threshold: 5.0)
    ro_inf = 2.0 / (1 - opts[:b2]) - 1
    mu = update_moment(x, mu, opts[:b1], 1)
    nu = update_moment(x, nu, opts[:b2], 2)
    count_inc = count + 1
    b2t = Nx.power(opts[:b2], count_inc)
    ro = (ro_inf - 2) * count_inc * b2t / (1 - b2t)
    mu_hat = bias_correction(mu, opts[:b1], count_inc)
    nu_hat = bias_correction(nu, opts[:b2], count_inc)

    x =
      if Nx.greater_equal(ro, opts[:threshold]) do
        radam_update(ro, ro_inf, mu_hat, nu_hat, opts[:eps_root], opts[:eps])
      else
        mu_hat
      end

    {x, mu, nu}
  end

  defnp radam_update(ro, ro_inf, mu, nu, eps_root, eps) do
    r = Nx.sqrt((ro - 4) * (ro - 2) * ro_inf / ((ro_inf - 4) * (ro_inf - 2) * ro))
    Nx.divide(Nx.multiply(r, mu), Nx.sqrt(nu + eps_root) + eps)
  end

  @doc """
  Trace inputs with past inputs.

  Returns `{traced_inputs, updated_trace}`.

  ## Options

    * `:decay` - decay rate for tracing past updates. Defaults
      to `0.9`
    * `:nesterov` - whether to use Nesterov momentum. Defaults
      to `false`

  """
  defn trace(x, trace, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, nesterov: false)
    update_trace = x + opts[:decay] * trace

    x =
      if to_predicate(opts[:nesterov]) do
        x + opts[:decay] * update_trace
      else
        update_trace
      end

    {x, update_trace}
  end

  @doc """
  Clips input between -delta and delta.

  ## Options

    * `:delta` - maximum absolute value of the input. Defaults
      to `2.0`

  ## Examples

      iex> Axon.Updates.clip(Nx.tensor([-3.0, -2.5, 0.0, 2.0, 1.0]))
      #Nx.Tensor<
        f64[5]
        [-2.0, -2.0, 0.0, 2.0, 1.0]
      >

      iex> Axon.Updates.clip(Nx.tensor([-5, -3, -1, 0, 2, 10, 4]), delta: 2.5)
      #Nx.Tensor<
        f64[7]
        [-2.5, -2.5, -1.0, 0.0, 2.0, 2.5, 2.5]
      >

  """
  defn clip(x, opts \\ []) do
    opts = keyword!(opts, delta: 2.0)
    delta = opts[:delta]
    Nx.clip(x, -delta, delta)
  end

  @doc """
  Clips input using input global norm.

  ## Options

    * `:max_norm` - maximum norm value of input. Defaults to
      `1.0`

  """
  defn clip_by_global_norm(x, opts \\ []) do
    opts = keyword!(opts, [max_norm: 1.0])
    max_norm = opts[:max_norm]

    g_norm =
      x
      |> Nx.power(2)
      |> Nx.sum()
      |> Nx.sqrt()

    Nx.select(Nx.less(g_norm, max_norm), x, x / g_norm * max_norm)
  end

  @doc """
  Centralize input.

  ## Examples

    iex> Axon.Updates.centralize(Nx.tensor([2.0, -3.0, 1.0, 2.0, -3.0]))
    #Nx.Tensor<
      f64[5]
      [2.2, -2.8, 1.2, 2.2, -2.8]
    >

    iex> Axon.Updates.centralize(Nx.tensor([[1.0, -2.0, 5.0, 10.0], [2.0, 3.0, 4.0, 5.0]]))
    #Nx.Tensor<
      f64[2][4]
      [
        [-2.5, -5.5, 1.5, 6.5],
        [-1.5, -0.5, 0.5, 1.5]
      ]
    >

  """
  defn centralize(x) do
    x
    |> Nx.mean()
    |> Nx.negate()
    |> Nx.add(x)
  end

  ## Helpers

  defnp update_moment(x, moment, decay, order) do
    (1 - decay) * Nx.power(x, order) + Nx.multiply(decay, moment)
  end

  defnp bias_correction(moment, decay, count) do
    correction = 1 - Nx.power(decay, count)
    Nx.divide(moment, correction)
  end

  defnp safe_norm(x, min_norm) do
    norm = Nx.norm(x)
    x = Nx.select(Nx.less(norm, min_norm), 1, x)
    Nx.select(Nx.less(norm, min_norm), min_norm, Nx.norm(x))
  end
end

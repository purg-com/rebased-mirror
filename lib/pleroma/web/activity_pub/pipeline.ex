# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Pipeline do
  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.SideEffects
  alias Pleroma.Web.Federator
  alias Pleroma.Config

  @spec common_pipeline(map(), keyword()) ::
          {:ok, Activity.t() | Object.t(), keyword()} | {:error, any()}
  def common_pipeline(object, meta) do
    case Repo.transaction(fn -> do_common_pipeline(object, meta) end) do
      {:ok, value} ->
        value

      {:error, e} ->
        {:error, e}
    end
  end

  def do_common_pipeline(object, meta) do
    with {_, {:ok, validated_object, meta}} <-
           {:validate_object, ObjectValidator.validate(object, meta)},
         {_, {:ok, mrfd_object}} <- {:mrf_object, MRF.filter(validated_object)},
         {_, {:ok, activity, meta}} <-
           {:persist_object, ActivityPub.persist(mrfd_object, meta)},
         {_, {:ok, activity, meta}} <-
           {:execute_side_effects, SideEffects.handle(activity, meta)},
         {_, {:ok, _}} <- {:federation, maybe_federate(activity, meta)} do
      {:ok, activity, meta}
    else
      {:mrf_object, {:reject, _}} -> {:ok, nil, meta}
      e -> {:error, e}
    end
  end

  defp maybe_federate(%Object{}, _), do: {:ok, :not_federated}

  defp maybe_federate(%Activity{} = activity, meta) do
    with {:ok, local} <- Keyword.fetch(meta, :local) do
      do_not_federate = meta[:do_not_federate] || !Config.get([:instance, :federating])

      if !do_not_federate && local do
        Federator.publish(activity)
        {:ok, :federated}
      else
        {:ok, :not_federated}
      end
    else
      _e -> {:error, :badarg}
    end
  end
end

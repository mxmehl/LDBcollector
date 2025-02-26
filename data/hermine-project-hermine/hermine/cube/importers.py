# SPDX-FileCopyrightText: 2021 Hermine-team <hermine@inno3.fr>
# SPDX-FileCopyrightText: 2022 Martin Delabre <gitlab.com/delabre.martin>
#
# SPDX-License-Identifier: AGPL-3.0-only

import json
import logging
from datetime import datetime

from django.core.files.uploadedfile import TemporaryUploadedFile
from django.db import transaction
from packageurl import PackageURL
from spdx_tools.spdx.model import ExternalPackageRefCategory
from spdx_tools.spdx.parser.error import SPDXParsingError
from spdx_tools.spdx.parser.parse_anything import parse_file

from cube.models import Component, Version, Usage, Exploitation
from cube.utils.spdx import is_valid, simplified

logger = logging.getLogger(__name__)


class SBOMImportFailure(Exception):
    pass


@transaction.atomic()
def import_ort_evaluated_model_json_file(
    json_file, release_id, replace=False, linking: str = ""
):
    try:
        data = json.load(json_file)
    except ValueError:
        raise SBOMImportFailure("This is not a valid JSON file.")

    try:
        paths = data["paths"]
    except KeyError:
        raise SBOMImportFailure("paths key not found in the file.")

    try:
        scopes = data["scopes"]
    except KeyError:
        raise SBOMImportFailure("scopes key not found in the file.")

    try:
        packages = data["packages"]
    except KeyError:
        raise SBOMImportFailure("packages key not found in the file.")

    try:
        licenses = data["licenses"]
    except KeyError:
        raise SBOMImportFailure("licenses key not found in the file.")

    if replace:
        Usage.objects.filter(release=release_id).delete()

    for package in packages:
        if package["is_project"]:
            continue
        package_id = package["id"]

        # If there is no Purl field, we recreate it from the ORT ID
        if (current_purl := package.get("purl")) is None:
            logger.info(f"Purl is null for {package_id}")
            p_type = package_id[0 : package_id.find(":")]
            p_version = package_id[package_id.rfind(":") + 1 :]
            if len(p_version) == 0:
                p_version = "AUTOGENERATED"
            p_name = package["id"][
                package["id"].find(":") + 1 : package["id"].rfind(":")
            ].replace(":", "/")
            # TODO Maybe trace the fact that it's generated
            current_purl = str(
                PackageURL(type=p_type.lower(), name=p_name, version=p_version)
            )  # p_name can contain namespace at this point, not a problem because they are stored together anyway

        purl = PackageURL.from_string(current_purl)
        comp_name = f"{purl.namespace}/{purl.name}" if purl.namespace else purl.name
        version_number = current_purl.split("@")[1]

        declared_licenses_indices = package.get("declared_licenses", "")
        if declared_licenses_indices:
            declared_licenses = " ; ".join(
                [
                    licenses[license_index]["id"]
                    for license_index in declared_licenses_indices
                ]
            )
        else:
            declared_licenses = ""
        spdx_valid_license = package["declared_licenses_processed"].get(
            "spdx_expression", ""
        )
        if spdx_valid_license == "NOASSERTON":
            spdx_valid_license = ""

        path_ids = package.get("paths", [])

        if path_ids:
            for path_id in path_ids:
                path = paths[path_id]
                scope_id = path.get("scope")
                project_id = path.get("project")
                scope_name = scopes[scope_id]["name"]
                project_name = packages[project_id]["id"]

                add_dependency(
                    release_id,
                    purl.type,
                    comp_name,
                    {
                        "description": package.get("description", ""),
                        "homepage_url": package.get("homepage_url", ""),
                    },
                    version_number,
                    declared_licenses,
                    spdx_valid_license,
                    linking,
                    current_purl,
                    scope_name,
                    project_name,
                )
        else:
            add_dependency(
                release_id,
                purl.type,
                comp_name,
                {
                    "description": package.get("description", ""),
                    "homepage_url": package.get("homepage_url", ""),
                },
                version_number,
                declared_licenses,
                spdx_valid_license,
                linking,
                current_purl,
            )


@transaction.atomic()
def import_spdx_file(spdx_file, release_id, replace=False, linking: str = ""):
    # Importing SPDX BOM yaml
    logger.info("SPDX import started")
    try:
        document = parse_spdx_file(spdx_file)
    except SPDXParsingError as e:
        raise SBOMImportFailure(f"Could not parse SPDX file : {e.messages}")

    if replace:
        Usage.objects.filter(release=release_id).delete()

    for package in document.packages:
        comp_name = package.name
        comp_url = (
            package.download_location
            if package.download_location is not None
            and str(package.download_location) != "NOASSERTION"
            else ""
        )

        declared_license = (
            str(package.license_declared)
            if package.license_declared is not None
            else ""
        )

        concluded_license = (
            str(package.license_concluded)
            if package.license_concluded is not None
            and str(package.license_concluded) != "NOASSERTION"
            else ""
        )

        version_number = package.version or "Current"

        purl = next(
            (
                ref.locator
                for ref in package.external_references
                if ref.reference_type == "purl"
                and ref.category == ExternalPackageRefCategory.PACKAGE_MANAGER
            ),
            "",
        )

        add_dependency(
            release_id,
            "",
            comp_name,
            {"homepage_url": comp_url},
            version_number,
            declared_license,
            concluded_license,
            linking,
            purl,
        )

    logger.info("SPDX import done", datetime.now())


def add_dependency(
    release_id,
    component_purl_type,
    component_name,
    component_defaults,
    version_number,
    declared_license,
    concluded_license,
    linking,
    purl="",
    scope=Usage.DEFAULT_SCOPE,
    project=Usage.DEFAULT_PROJECT,
):
    # ORT has not concluded license, but declared license is valid
    if not concluded_license and is_valid(declared_license):
        concluded_license = declared_license

    if purl:
        purl_obj = PackageURL.from_string(purl)
        # Prefer the purl name over the explicit component name
        component_name = (
            f"{purl_obj.namespace}/{purl_obj.name}"
            if purl_obj.namespace
            else purl_obj.name
        ) or component_name
        # Prefer explicit type over the purl type
        component_purl_type = component_purl_type or purl_obj.type

    component, component_log = add_component(
        component_purl_type, component_name, component_defaults
    )

    version, version_log = add_version(
        component,
        version_number,
        declared_license=declared_license,
        concluded_license=concluded_license,
        purl=purl,
    )

    try:
        exploitation = Exploitation.objects.get(
            release=release_id, project=project, scope=scope
        ).exploitation
    except Exploitation.DoesNotExist:
        exploitation = ""

    Usage.objects.get_or_create(
        version_id=version.id,
        release_id=release_id,
        project=project,
        exploitation=exploitation,
        scope=scope,
        description=component_log + version_log,
        defaults={"addition_method": "Scan", "linking": linking},
    )


def add_component(component_purl_type, component_name, component_defaults):
    import_log = ""
    component = Component.objects.filter(
        purl_type=component_purl_type, name=component_name
    ).first()

    if component is not None:
        save_component = False
        component_conflicts = set()
        import_conflicts = []

        if component_defaults.get("description", ""):
            if not component.description:
                component.description = component_defaults["description"]
                save_component = True
            elif component.description != component_defaults["description"]:
                import_conflicts.append(
                    f"* description is {component_defaults['description']} in import but {component.description}"
                    f" in local data"
                )

        if component_defaults.get("homepage_url", ""):
            if not component.homepage_url:
                component.homepage_url = component_defaults.get("homepage_url", "")
                save_component = True
            elif component.homepage_url != component_defaults.get("homepage_url", ""):
                import_conflicts.append(
                    f"* homepage_url is {component_defaults['homepage_url']} in import but {component.homepage_url}"
                    f" in local data"
                )

        if save_component:
            component.save()

        if len(import_conflicts) > 0:
            import_log += f"Conflicting values for {', '.join(component_conflicts)} fields on component {component_name} :\n"
            for line in import_conflicts:
                import_log += line
            import_log += "\n"

    else:
        component = Component.objects.create(
            purl_type=component_purl_type,
            name=component_name,
            **component_defaults,
        )

    return component, import_log


def add_version(component, version_number, declared_license, concluded_license, purl):
    import_log = ""
    version = Version.objects.filter(
        component=component, version_number=version_number
    ).first()

    if version is not None:
        # Same as for component, we update empty fields with default values
        # and keep tract of conflicting fields
        save_version = False
        version_conflicts = set()

        if not version.declared_license_expr:
            version.declared_license_expr = declared_license
            save_version = True
        elif version.declared_license_expr != declared_license:
            version_conflicts.add("declared_license_expr")

        if not version.spdx_valid_license_expr:
            version.spdx_valid_license_expr = concluded_license
            save_version = True
        elif version.spdx_valid_license_expr != concluded_license:
            version_conflicts.add("spdx_valid_license_expr")

        if not version.purl:
            version.purl = purl
            save_version = True
        elif version.purl != purl:
            version_conflicts.add("purl")

        if save_version:
            version.save()

        if len(version_conflicts) > 0:
            import_values = {
                "declared_license_expr": declared_license,
                "spdx_valid_license_expr": concluded_license,
                "purl": purl,
            }
            import_log += f"Conflicting values for {', '.join(version_conflicts)} fields on version {version_number} :\n"
            for field in version_conflicts:
                import_log += f"* {field} is {import_values[field]} in import but {getattr(version, field)} in local data\n"
            import_log += "\n"

    else:
        version = Version.objects.create(
            component=component,
            version_number=version_number,
            declared_license_expr=declared_license,
            spdx_valid_license_expr=concluded_license and simplified(concluded_license),
            purl=purl,
        )

    return version, import_log


# Function derivated from
# https://github.com/spdx/tools-python/blob/21ea183f72a1179c62ec146a992ec5642cc5f002/spdx/parsers/parse_anything.py
# SPDX-FileCopyrightText: spdx contributors
# SPDX-License-Identifier: Apache-2.0
def parse_spdx_file(spdx_file):
    if isinstance(spdx_file, TemporaryUploadedFile):
        return parse_file(spdx_file.temporary_file_path())

    return parse_file(spdx_file.name)
